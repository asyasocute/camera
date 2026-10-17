import AVFoundation
import ImageIO

struct Lens: Identifiable, Hashable, Sendable {
    let id: String
    let zoom: Double
    let isFront: Bool
    /// The back wide-angle camera, which the system labels 1×.
    let isMain: Bool

    var label: String { shortLabel + "×" }

    var shortLabel: String {
        zoom.formatted(.number.precision(.fractionLength(0...1)))
    }
}

enum RawKind: Sendable {
    /// Unprocessed sensor data.
    case bayer
    /// Demosaiced and partially processed; the only RAW some cameras (e.g. the front one) offer.
    case proRAW
}

struct ExposureRange: Equatable, Sendable {
    var minISO: Double
    var maxISO: Double
    var minDuration: Double
    var maxDuration: Double
    var minBias: Double
    var maxBias: Double
}

struct LensState: Equatable, Sendable {
    let lens: Lens
    let exposureRange: ExposureRange
    let supportsManualExposure: Bool
    let supportsManualFocus: Bool
    let supportsManualWhiteBalance: Bool
    let hasFlash: Bool
    let raw: RawKind?
}

/// What the user asked for. AVFoundation only has full auto and full manual; the two priority modes
/// run in custom mode with the free parameter steered by the device's own meter.
enum Exposure: Equatable, Sendable {
    case auto
    case manual(iso: Double, duration: Double)
    /// Fixed shutter, ISO follows metering.
    case shutterPriority(duration: Double)
    /// Fixed ISO, shutter follows metering, no slower than `CaptureService.slowestStreamShutter`.
    case isoPriority(iso: Double)
}

enum WhiteBalance: Equatable, Sendable {
    case auto
    /// Locked at a color temperature in kelvin, zero tint.
    case temperature(Double)

    static let kelvinRange = 2000.0...10000.0
}

/// The camera meters flash shots itself: AVFoundation overrides custom exposure and locked white
/// balance for them, so manual values apply only to shots without flash.
enum Flash: String, Sendable {
    case off, auto, on

    /// Auto follows the camera's own judgement of whether the scene is dark enough.
    func fires(inFlashScene flashScene: Bool) -> Bool {
        self == .on || self == .auto && flashScene
    }
}

struct Readout: Equatable, Sendable {
    var iso: Double
    var duration: Double
    var lensPosition: Double
    var temperature: Double
    /// The camera finds the scene dark enough for the flash.
    var flashScene: Bool
    /// The lens has a flash and it isn't off for cooling down.
    var flashReady: Bool

    static let zero = Readout(iso: 0, duration: 0, lensPosition: 0, temperature: 0, flashScene: false, flashReady: false)
}

struct CapturedRAW: Sendable {
    /// Temporary file, so shots waiting for development queue up on disk instead of in memory.
    let dng: URL
    let kind: RawKind
    let orientation: CGImagePropertyOrientation
    /// Share of photosites at sensor saturation; nil for ProRAW or when the white level is unknown.
    let clippedFraction: Double?
    let iso: Double?
    let exposureTime: Double?
}

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case rawUnavailable
    case notRunning
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "Camera not found")
        case .cannotAddInput: String(localized: "Couldn't connect the lens")
        case .cannotAddOutput: String(localized: "Couldn't set up photo capture")
        case .rawUnavailable: String(localized: "RAW isn't available on this lens")
        case .notRunning: String(localized: "The camera isn't running")
        case .emptyCapture: String(localized: "The camera returned no data")
        }
    }
}

/// Owns the AVCaptureSession. All mutable state is confined to `queue`.
final class CaptureService: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var rawFormat: (type: OSType, kind: RawKind)?
    private var inFlight: [Int64: RawCaptureDelegate] = [:]
    private var paused = false

    private var exposure = Exposure.auto
    private let exposureUpdates = Coalescer()
    private var whiteBalance = WhiteBalance.auto
    private let whiteBalanceUpdates = Coalescer()
    /// nil = continuous autofocus.
    private var focusTarget: Double?
    private let focusUpdates = Coalescer()
    private var exposureBias = 0.0
    private let biasUpdates = Coalescer()
    private var flash = Flash.off
    /// The pre-flash brightens the scene; metering it would leave the viewfinder dark after the shot.
    private var flashCapturesInFlight: Set<Int64> = []
    private var meterTimer: DispatchSourceTimer?
    /// Set while a metering step is on its way to the sensor; cleared by the device's completion.
    private var meterStepDeadline: DispatchTime?
    /// The meter needs one frame with the new exposure before its reading means anything.
    private var meterSettledAt = DispatchTime.now()
    /// Bayer RAW formats that take a manual-exposure bracket can shoot long exposures as a single
    /// bracketed frame while the viewfinder keeps a short shutter.
    private var canBracket = false

    /// Slowest shutter the viewfinder stream and auto exposure use. Longer manual shutters are applied
    /// only to the photo, so the viewfinder doesn't drop to one frame per second.
    static let slowestStreamShutter = 1.0 / 24
    /// When even max ISO can't show a long shutter's brightness at 1/24 s, the viewfinder may slow
    /// down this far (8 fps) instead of going dark. Beyond it the viewfinder is darker than the photo.
    static let slowestCompensatingShutter = 1.0 / 8

    private var device: AVCaptureDevice? { input?.device }

    func lenses() async -> [Lens] {
        await perform { Self.discoverLenses() }
    }

    func select(lensID: String) async throws -> LensState {
        try await perform {
            let state = try self.configure(lensID: lensID)
            self.updateRunning()
            return state
        }
    }

    /// Stops the camera while something covers the preview. Stopping mid-capture would cancel the photo,
    /// so a pause takes effect once in-flight captures have been delivered.
    func setPaused(_ paused: Bool) {
        queue.async {
            self.paused = paused
            self.updateRunning()
        }
    }

    /// ISO and shutter the next photo gets, which differ from the viewfinder's for long shutters.
    func readout() async -> Readout {
        await perform {
            guard let d = self.device else { return .zero }
            let photo = self.photoExposure(d)
            // The live gains can sit slightly outside 1...maxWhiteBalanceGain, which makes the conversion throw.
            let white = d.temperatureAndTintValues(for: Self.valid(d.deviceWhiteBalanceGains, for: d))
            return Readout(
                iso: photo.iso,
                duration: photo.duration,
                lensPosition: Double(d.lensPosition),
                temperature: white.temperature.isFinite ? Double(white.temperature) : 0,
                flashScene: self.photoOutput.isFlashScene,
                flashReady: self.flashReady(d)
            )
        }
    }

    func setFlash(_ flash: Flash) {
        queue.async { self.flash = flash }
    }

    func setExposure(_ exposure: Exposure) {
        queue.async {
            self.exposure = exposure
            self.exposureUpdates.schedule(on: self.queue) { self.applyExposure() }
        }
    }

    func setWhiteBalance(_ whiteBalance: WhiteBalance) {
        queue.async {
            self.whiteBalance = whiteBalance
            self.whiteBalanceUpdates.schedule(on: self.queue) { self.applyWhiteBalance() }
        }
    }

    func setExposureBias(_ ev: Double) {
        queue.async {
            self.exposureBias = ev
            self.biasUpdates.schedule(on: self.queue) {
                self.withLockedDevice { d in
                    d.setExposureTargetBias(Float(self.exposureBias).clamped(d.minExposureTargetBias, d.maxExposureTargetBias))
                }
            }
        }
    }

    /// nil = continuous autofocus, otherwise a locked lens position (0...1).
    func setFocus(_ target: Double?) {
        queue.async {
            self.focusTarget = target
            self.focusUpdates.schedule(on: self.queue) { self.applyFocus() }
        }
    }

    /// `point` is in device coordinates (0...1, landscape-right sensor space).
    func focus(at point: CGPoint, meterExposure: Bool) {
        withDevice { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = point
                d.focusMode = .continuousAutoFocus
            }
            if meterExposure, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = point
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Captures a single RAW frame: Bayer where available, otherwise ProRAW without multi-frame fusion.
    /// `rotationAngle` is in back-camera terms (see `OrientationTracker.Orientation.captureAngle`).
    /// `exposed` runs on the photo output's queue as soon as the sensor has taken the frame, which is
    /// when the next shot can start; the result follows once the DNG is on disk.
    func capture(
        rotationAngle: CGFloat,
        location: PhotoLocation?,
        exposed: @escaping @Sendable () -> Void
    ) async throws -> CapturedRAW {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedRAW, Error>) in
            queue.async {
                guard let format = self.rawFormat else {
                    cont.resume(throwing: CameraError.rawUnavailable)
                    return
                }
                guard self.session.isRunning, !self.paused else {
                    cont.resume(throwing: CameraError.notRunning)
                    return
                }
                let settings = self.photoSettings(rawFormat: format.type)
                // Required for Bayer RAW; for ProRAW it skips the fusion of multiple frames.
                settings.photoQualityPrioritization = .speed

                var angle = Self.captureAngle(rotationAngle, front: self.device?.position == .front)
                if let connection = self.photoOutput.connection(with: .video) {
                    angle = connection.applyRotation(angle)
                    // Selfies are saved as others see you, like the system camera's default.
                    if connection.isVideoMirroringSupported, connection.automaticallyAdjustsVideoMirroring || connection.isVideoMirrored {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }

                let id = settings.uniqueID
                let delegate = RawCaptureDelegate(kind: format.kind, rotationAngle: angle, location: location, exposed: exposed) { result in
                    self.queue.async {
                        self.inFlight[id] = nil
                        if self.flashCapturesInFlight.remove(id) != nil {
                            // Give the meter a frame lit by the ambient light alone before it steps again.
                            self.meterSettledAt = max(self.meterSettledAt, .now() + 0.2)
                            self.restoreAfterFlash()
                        }
                        self.updateRunning()
                    }
                    cont.resume(with: result)
                }
                self.inFlight[id] = delegate
                if settings.flashMode == .on { self.flashCapturesInFlight.insert(id) }
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// The front sensor is mounted mirrored relative to the back one, which reverses the direction of
    /// rotation: portrait angles stay the same and the two landscape angles swap.
    private static func captureAngle(_ backAngle: CGFloat, front: Bool) -> CGFloat {
        guard front else { return backAngle }
        let angle = (180 - backAngle).truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : angle
    }

    // MARK: - Focus (session queue)

    private func applyFocus() {
        withLockedDevice { d in
            if let position = focusTarget {
                guard d.isLockingFocusWithCustomLensPositionSupported else { return }
                d.setFocusModeLocked(lensPosition: Float(position).clamped(0, 1))
            } else if d.focusMode != .continuousAutoFocus, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
        }
    }

    /// The flash sequence meters on its own over custom exposure and locked white balance, and has been
    /// reported to refocus over a locked lens. Applying the user's settings again returns the viewfinder
    /// to them; for settings the device kept, it changes nothing.
    private func restoreAfterFlash() {
        exposureUpdates.schedule(on: queue) { self.applyExposure() }
        whiteBalanceUpdates.schedule(on: queue) { self.applyWhiteBalance() }
        focusUpdates.schedule(on: queue) { self.applyFocus() }
    }

    // MARK: - White balance (session queue)

    private func applyWhiteBalance() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        switch whiteBalance {
        case .auto:
            // Only when it isn't on yet, so re-applying after a flash shot leaves running auto white balance alone.
            if d.whiteBalanceMode != .continuousAutoWhiteBalance, d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        case let .temperature(kelvin):
            // Without support only the current gains may be locked; anything else throws.
            guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: 0)
            d.setWhiteBalanceModeLocked(with: Self.valid(d.deviceWhiteBalanceGains(for: values), for: d))
        }
    }

    /// AVFoundation throws for any gain outside 1...maxWhiteBalanceGain, both when locking and converting.
    private static func valid(_ gains: AVCaptureDevice.WhiteBalanceGains, for d: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = max(d.maxWhiteBalanceGain, 1)
        var gains = gains
        gains.redGain = gains.redGain.isFinite ? gains.redGain.clamped(1, maxGain) : 1
        gains.greenGain = gains.greenGain.isFinite ? gains.greenGain.clamped(1, maxGain) : 1
        gains.blueGain = gains.blueGain.isFinite ? gains.blueGain.clamped(1, maxGain) : 1
        return gains
    }

    // MARK: - Exposure (session queue)

    private func applyExposure() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        // Current brightness, kept when switching into a priority mode so the image doesn't jump.
        let product = Double(d.iso) * d.exposureDuration.seconds
        switch exposure {
        case .auto:
            // Re-setting the mode would restart auto exposure.
            if d.exposureMode != .continuousAutoExposure, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
        case let .manual(iso, duration):
            let stream = streamExposure(product: iso * duration, photoDuration: duration, d)
            setCustom(d, iso: stream.iso, duration: stream.duration)
        case let .shutterPriority(duration):
            let stream = streamExposure(product: product, photoDuration: duration, d)
            setCustom(d, iso: stream.iso, duration: stream.duration)
        case let .isoPriority(iso):
            setCustom(d, iso: iso, duration: min(product / iso, Self.slowestStreamShutter))
        }
        updateMeterTimer()
    }

    /// Steers the free parameter of a priority mode toward the meter's target, which includes the EV
    /// bias. Runs every 33 ms but steps only once the previous step has reached the sensor (the
    /// device's completion handler) and the meter has seen a frame of it, so it converges quickly
    /// without hunting: errors over 1 EV are corrected in one step, smaller ones at 80%.
    private func meter() {
        guard session.isRunning, flashCapturesInFlight.isEmpty, let d = device, d.exposureMode == .custom else { return }
        let now = DispatchTime.now()
        if let deadline = meterStepDeadline {
            // The completion can be lost when the session reconfigures; don't wait for it forever.
            guard now >= deadline else { return }
            meterStepDeadline = nil
        }
        guard now >= meterSettledAt else { return }
        let offset = Double(d.exposureTargetOffset)
        guard offset.isFinite, abs(offset) > 0.1 else { return }
        let factor = pow(2, -offset * (abs(offset) > 1 ? 1 : 0.8))
        let f = d.activeFormat
        let currentDuration = d.exposureDuration.seconds

        let iso: Double, duration: Double
        switch exposure {
        case let .shutterPriority(shutter):
            let target = Double(d.iso) * currentDuration * factor
            let stream = streamExposure(product: target, photoDuration: shutter, d)
            // Compare what the device will actually get: pinned at max ISO, nothing changes.
            iso = stream.iso.clamped(Double(f.minISO), Double(f.maxISO))
            duration = stream.duration
            guard abs(iso * duration / (Double(d.iso) * currentDuration) - 1) > 0.02 else { return }
        case let .isoPriority(fixed):
            iso = fixed
            duration = (currentDuration * factor)
                .clamped(f.minExposureDuration.seconds, min(f.maxExposureDuration.seconds, Self.slowestStreamShutter))
            guard abs(duration / currentDuration - 1) > 0.02 else { return }
        case .auto, .manual:
            return
        }

        guard (try? d.lockForConfiguration()) != nil else { return }
        // A step can't land before the current frame ends, so the timeout scales with the frame length.
        let frame = max(currentDuration, duration)
        meterStepDeadline = now + max(0.5, 3 * frame)
        setCustom(d, iso: iso, duration: duration) { _ in
            self.queue.async {
                self.meterStepDeadline = nil
                self.meterSettledAt = .now() + max(1.0 / 30, duration)
            }
        }
        d.unlockForConfiguration()
    }

    private func updateMeterTimer() {
        let metered = switch exposure {
        case .shutterPriority, .isoPriority: true
        case .auto, .manual: false
        }
        if metered, meterTimer == nil {
            meterStepDeadline = nil
            meterSettledAt = .now()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
            timer.setEventHandler { self.meter() }
            timer.resume()
            meterTimer = timer
        } else if !metered, let timer = meterTimer {
            timer.cancel()
            meterTimer = nil
        }
    }

    /// Viewfinder shutter and ISO showing the photo's brightness (ISO × seconds). At 1/24 s or faster for
    /// a smooth viewfinder; slower, down to `slowestCompensatingShutter`, only when max ISO can't reach
    /// the brightness otherwise. Without bracketing the photo is taken from the stream, so it's exact.
    private func streamExposure(product: Double, photoDuration: Double, _ d: AVCaptureDevice) -> (iso: Double, duration: Double) {
        let f = d.activeFormat
        guard canBracket else { return (product / photoDuration, photoDuration) }
        let fastest = min(photoDuration, Self.slowestStreamShutter)
        let slowest = min(photoDuration, Self.slowestCompensatingShutter)
        let duration = (product / Double(f.maxISO)).clamped(fastest, slowest)
        return (product / duration, duration)
    }

    private func setCustom(
        _ d: AVCaptureDevice,
        iso: Double,
        duration: Double,
        applied: (@Sendable (CMTime) -> Void)? = nil
    ) {
        guard d.isExposureModeSupported(.custom) else { return }
        let f = d.activeFormat
        d.setExposureModeCustom(
            duration: CMTime(seconds: duration.clamped(f.minExposureDuration.seconds, f.maxExposureDuration.seconds), preferredTimescale: 1_000_000_000),
            iso: Float(iso).clamped(f.minISO, f.maxISO),
            completionHandler: applied
        )
    }

    /// Same brightness as the stream, moved to the photo's shutter for long manual shutters.
    private func photoExposure(_ d: AVCaptureDevice) -> (iso: Double, duration: Double) {
        let f = d.activeFormat
        let streamISO = Double(d.iso), streamDuration = d.exposureDuration.seconds
        let (iso, duration) = switch exposure {
        case let .manual(iso, duration): (iso, duration)
        case let .shutterPriority(duration): (streamISO * streamDuration / duration, duration)  // same brightness
        case .auto, .isoPriority: (streamISO, streamDuration)
        }
        return (
            iso.clamped(Double(f.minISO), Double(f.maxISO)),
            duration.clamped(f.minExposureDuration.seconds, f.maxExposureDuration.seconds)
        )
    }

    /// A one-frame manual bracket when the photo needs a longer shutter than the viewfinder runs at.
    /// Flash shots are plain captures: brackets can't fire the flash, and the camera meters flash shots
    /// itself anyway. Auto flash is resolved here instead of by the photo output, so a shot the camera
    /// takes without flash still gets its bracket, and the flash icon tells in advance which it will be.
    private func photoSettings(rawFormat: OSType) -> AVCapturePhotoSettings {
        guard let d = device else { return AVCapturePhotoSettings(rawPixelFormatType: rawFormat) }
        if flashReady(d), flash.fires(inFlashScene: photoOutput.isFlashScene) {
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            settings.flashMode = .on
            return settings
        }
        guard canBracket else { return AVCapturePhotoSettings(rawPixelFormatType: rawFormat) }
        let photo = photoExposure(d)
        guard photo.duration > d.exposureDuration.seconds * 1.05 else {
            return AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        }
        let frame = AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
            exposureDuration: CMTime(seconds: photo.duration, preferredTimescale: 1_000_000_000),
            iso: Float(photo.iso)
        )
        return AVCapturePhotoBracketSettings(rawPixelFormatType: rawFormat, processedFormat: nil, bracketedSettings: [frame])
    }

    /// The lens has a flash and it isn't switched off while the phone cools down. With `.on` and no
    /// flash available, the photo output would quietly shoot without it, so this is checked up front.
    /// Availability can only be checked when the device reports a flash of its own.
    private func flashReady(_ d: AVCaptureDevice) -> Bool {
        photoOutput.supportedFlashModes.contains(.on) && (!d.hasFlash || d.isFlashAvailable)
    }

    // MARK: - Session queue

    private func updateRunning() {
        if paused {
            if inFlight.isEmpty, session.isRunning { session.stopRunning() }
        } else if input != nil, !session.isRunning {
            session.startRunning()
        }
    }

    private func configure(lensID: String) throws -> LensState {
        guard let device = AVCaptureDevice(uniqueID: lensID),
              let lens = Self.discoverLenses().first(where: { $0.id == lensID })
        else { throw CameraError.noCamera }
        let newInput = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                throw CameraError.cannotAddOutput
            }
            session.addOutput(photoOutput)
        }
        if photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = false
        }
        session.commitConfiguration()

        rawFormat = photoOutput.availableRawPhotoPixelFormatTypes
            .first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            .map { ($0, .bayer) }
        // ProRAW only as a fallback: enabling it reconfigures the pipeline, and Bayer is the unprocessed option.
        if rawFormat == nil, photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
            rawFormat = photoOutput.availableRawPhotoPixelFormatTypes
                .first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
                .map { ($0, .proRAW) }
        }
        canBracket = rawFormat?.kind == .bayer && photoOutput.maxBracketedCapturePhotoCount > 0
        // isFlashScene answers only while a flash mode is monitored. Speed priority, like the RAW captures:
        // with still image stabilization monitored too, auto flash would wait for darker scenes.
        if photoOutput.supportedFlashModes.contains(.auto) {
            let monitoring = AVCapturePhotoSettings()
            monitoring.flashMode = .auto
            monitoring.photoQualityPrioritization = .speed
            photoOutput.photoSettingsForSceneMonitoring = monitoring
        } else {
            photoOutput.photoSettingsForSceneMonitoring = nil
        }
        prepareCaptures(on: device)
        // A new lens starts in auto exposure (set below), so any priority-mode metering stops.
        // White balance starts in auto too; the model re-applies a locked one.
        exposure = .auto
        whiteBalance = .auto
        updateMeterTimer()

        // The session already runs the new lens, so failing to lock must not fail the switch; it only
        // leaves the device's own defaults in place.
        if (try? device.lockForConfiguration()) != nil {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            // Video HDR fuses an under-exposed frame into every preview frame, so the preview shows highlights
            // that a single RAW frame clips. Turning it off makes the preview match what the sensor records.
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            // Auto exposure goes no slower than 1/24 s and raises ISO instead; manual keeps the full range.
            // Reset by the system on every format change, so it's applied here on each lens switch.
            let slowest = CMTime(value: 1, timescale: 24)
            if CMTimeCompare(slowest, device.activeFormat.minExposureDuration) >= 0 {
                device.activeMaxExposureDuration = CMTimeMinimum(slowest, device.activeFormat.maxExposureDuration)
            }
            device.unlockForConfiguration()
        }

        let f = device.activeFormat
        return LensState(
            lens: lens,
            exposureRange: ExposureRange(
                minISO: Double(f.minISO),
                maxISO: Double(f.maxISO),
                minDuration: f.minExposureDuration.seconds,
                maxDuration: f.maxExposureDuration.seconds,
                minBias: Double(device.minExposureTargetBias),
                maxBias: Double(device.maxExposureTargetBias)
            ),
            supportsManualExposure: device.isExposureModeSupported(.custom),
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported,
            supportsManualWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            hasFlash: photoOutput.supportedFlashModes.contains(.on),
            raw: rawFormat?.kind
        )
    }

    /// The photo output is prepared only for processed photos by default and allocates RAW and bracket
    /// buffers just in time, which slows those captures down; this allocates them now, on lens switch.
    private func prepareCaptures(on device: AVCaptureDevice) {
        guard let format = rawFormat else { return }
        let single = AVCapturePhotoSettings(rawPixelFormatType: format.type)
        single.photoQualityPrioritization = .speed
        var prepared = [single]
        if canBracket {
            let f = device.activeFormat
            let frame = AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: f.maxExposureDuration,
                iso: f.minISO
            )
            let bracket = AVCapturePhotoBracketSettings(rawPixelFormatType: format.type, processedFormat: nil, bracketedSettings: [frame])
            bracket.photoQualityPrioritization = .speed
            prepared.append(bracket)
        }
        photoOutput.setPreparedPhotoSettingsArray(prepared, completionHandler: nil)
    }

    private func withDevice(_ body: @escaping @Sendable (AVCaptureDevice) -> Void) {
        queue.async { self.withLockedDevice(body) }
    }

    /// Session queue only.
    private func withLockedDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        body(d)
        d.unlockForConfiguration()
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result(catching: body)) }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: body()) }
        }
    }

    /// Physical cameras only: virtual multi-camera devices don't deliver Bayer RAW.
    /// Back lenses sorted by zoom, then the front camera.
    private static func discoverLenses() -> [Lens] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        let back = devices.filter { $0.position == .back }
        let systemZoom = systemZoomFactors()
        let wideFOV = back.first { $0.deviceType == .builtInWideAngleCamera }?.activeFormat.videoFieldOfView

        var lenses = back.map { d in
            Lens(
                id: d.uniqueID,
                zoom: systemZoom[d.uniqueID] ?? estimatedZoom(of: d, wideFOV: wideFOV),
                isFront: false,
                isMain: d.deviceType == .builtInWideAngleCamera
            )
        }
        .sorted { $0.zoom < $1.zoom }

        if let front = devices.first(where: { $0.position == .front && $0.deviceType == .builtInWideAngleCamera }) {
            lenses.append(Lens(id: front.uniqueID, zoom: 1, isFront: true, isMain: false))
        }
        return lenses
    }

    /// Zoom of each back lens as the system camera labels it, keyed by device ID. Taken from the virtual
    /// device spanning the most lenses: its switch-over factors place each constituent relative to the
    /// widest one, and the display multiplier (iOS 18+) converts that to the UI convention where the
    /// main camera is 1×.
    private static func systemZoomFactors() -> [String: Double] {
        let virtual = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera],
            mediaType: .video,
            position: .back
        ).devices.max { $0.constituentDevices.count < $1.constituentDevices.count }
        guard let virtual else { return [:] }

        let constituents = virtual.constituentDevices
        let factors = [1.0] + virtual.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        guard factors.count == constituents.count else { return [:] }

        let multiplier: Double
        if #available(iOS 18, *) {
            multiplier = Double(virtual.displayVideoZoomFactorMultiplier)
        } else {
            let wide = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera }
            multiplier = wide.map { 1 / factors[$0] } ?? 1
        }
        return Dictionary(uniqueKeysWithValues: zip(constituents.map(\.uniqueID), factors.map { $0 * multiplier }))
    }

    /// Fallback when there is no virtual device: field-of-view ratio to the main camera, in half steps.
    private static func estimatedZoom(of device: AVCaptureDevice, wideFOV: Float?) -> Double {
        switch device.deviceType {
        case .builtInUltraWideCamera: 0.5
        case .builtInTelephotoCamera:
            wideFOV.map { max(2, (2 * halfTan($0) / halfTan(device.activeFormat.videoFieldOfView)).rounded() / 2) } ?? 2
        default: 1
        }
    }

    private static func halfTan(_ fovDegrees: Float) -> Double {
        tan(Double(fovDegrees) * .pi / 360)
    }
}

private final class RawCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let kind: RawKind
    private let rotationAngle: CGFloat
    private let location: PhotoLocation?
    private let exposed: @Sendable () -> Void
    private let completion: @Sendable (Result<CapturedRAW, Error>) -> Void
    private var result: CapturedRAW?
    private var error: Error?

    init(
        kind: RawKind,
        rotationAngle: CGFloat,
        location: PhotoLocation?,
        exposed: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<CapturedRAW, Error>) -> Void
    ) {
        self.kind = kind
        self.rotationAngle = rotationAngle
        self.location = location
        self.exposed = exposed
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        exposed()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            self.error = error
            return
        }
        guard photo.isRawPhoto, let dng = Self.fileData(of: photo, location: location) else { return }
        let clipped = photo.pixelBuffer.flatMap { buffer in
            RawStats.whiteLevel(of: dng).flatMap { RawStats.clippedFraction(buffer, whiteLevel: $0) }
        }
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let url = CaptureFiles.newDNG()
        do {
            try dng.write(to: url)
        } catch {
            self.error = error
            return
        }
        result = CapturedRAW(
            dng: url,
            kind: kind,
            orientation: Self.orientation(of: photo) ?? Self.orientation(forRotation: rotationAngle),
            clippedFraction: clipped,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first,
            exposureTime: exif?[kCGImagePropertyExifExposureTime as String] as? Double
        )
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? self.error {
            completion(.failure(error))
        } else if let result {
            completion(.success(result))
        } else {
            completion(.failure(CameraError.emptyCapture))
        }
    }

    /// The DNG with a GPS block added. If the customized write fails, the plain DNG is kept: the location
    /// still reaches Photos and the developed file.
    private static func fileData(of photo: AVCapturePhoto, location: PhotoLocation?) -> Data? {
        guard let location else { return photo.fileDataRepresentation() }
        return photo.fileDataRepresentation(with: GPSMetadata(gps: location.gpsMetadata)) ?? photo.fileDataRepresentation()
    }

    /// EXIF orientation for buffers rotated clockwise by the connection angle, used if the metadata has none.
    /// The angle is already sensor-specific, so this holds for the front camera too.
    private static func orientation(forRotation angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle.rounded()) {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    private static func orientation(of photo: AVCapturePhoto) -> CGImagePropertyOrientation? {
        let tiff = photo.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let value = photo.metadata[kCGImagePropertyOrientation as String] ?? tiff?[kCGImagePropertyTIFFOrientation as String]
        return (value as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
    }
}

private final class GPSMetadata: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let gps: [String: Any]

    init(gps: [String: Any]) {
        self.gps = gps
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        return metadata
    }
}

/// Collapses a burst of requests (slider drags send dozens a second) into one run of the work, which
/// then sees the latest state. Confined to the queue it schedules on.
private final class Coalescer: @unchecked Sendable {
    private var scheduled = false

    func schedule(on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        guard !scheduled else { return }
        scheduled = true
        queue.async {
            self.scheduled = false
            work()
        }
    }
}

/// Temporary DNGs between capture and saving to Photos.
enum CaptureFiles {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Captures", isDirectory: true)

    static func newDNG() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Leftovers of a session that ended mid-queue.
    static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum RawStats {
    static func whiteLevel(of dng: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(dng as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dngProps = props[kCGImagePropertyDNGDictionary] as? [CFString: Any]
        else { return nil }
        switch dngProps[kCGImagePropertyDNGWhiteLevel] {
        case let level as Int: return level
        case let levels as [Int]: return levels.min()
        default: return nil
        }
    }

    /// Samples every third photosite (odd stride keeps all CFA colors) of a 16-bit Bayer buffer.
    static func clippedFraction(_ buffer: CVPixelBuffer, whiteLevel: Int) -> Double? {
        guard AVCapturePhotoOutput.isBayerRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer)) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 0,
              rowBytes >= width * MemoryLayout<UInt16>.size,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }

        let threshold = UInt16(clamping: whiteLevel * 98 / 100)
        var clipped = 0
        var total = 0
        var peak: UInt16 = 0
        for y in stride(from: 0, to: height, by: 3) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: 0, to: width, by: 3) {
                let v = row[x]
                if v >= threshold { clipped += 1 }
                if v > peak { peak = v }
                total += 1
            }
        }
        // Buffer values above the DNG white level mean the two use different scales; don't report a guess.
        guard total > 0, Int(peak) <= whiteLevel * 102 / 100 else { return nil }
        return Double(clipped) / Double(total)
    }
}

extension AVCaptureConnection {
    /// `videoRotationAngle` is iOS 17+; earlier systems take the equivalent `videoOrientation`
    /// (0° landscape right, 90° portrait, 180° landscape left, 270° portrait upside down).
    /// Set only on change, since it also runs between the shutter press and the capture request.
    /// - Returns: the angle in effect afterwards.
    @discardableResult
    func applyRotation(_ angle: CGFloat) -> CGFloat {
        if #available(iOS 17, *) {
            if videoRotationAngle != angle, isVideoRotationAngleSupported(angle) { videoRotationAngle = angle }
            return videoRotationAngle
        }
        guard isVideoOrientationSupported else { return 0 }
        let orientation: AVCaptureVideoOrientation = switch Int(angle.rounded()) {
        case 90: .portrait
        case 180: .landscapeLeft
        case 270: .portraitUpsideDown
        default: .landscapeRight
        }
        if videoOrientation != orientation { videoOrientation = orientation }
        return angle
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self {
        min(max(self, lo), hi)
    }
}
