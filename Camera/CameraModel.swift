import AVFoundation
import Combine
import UIKit

/// Live camera values, polled ~7×/s. Separate from CameraModel so only the views showing them
/// re-render on every poll, not the whole camera screen.
@MainActor
final class LiveReadout: ObservableObject {
    @Published fileprivate(set) var value = Readout.zero
}

@MainActor
final class CameraModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case running
        case denied
        case failed(String)
    }

    let service = CaptureService()
    private let darkroom = Darkroom()
    private let orientation = OrientationTracker()
    let gallery = GalleryStore()

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var state: LensState?
    let live = LiveReadout()
    let location = LocationProvider()
    private var readout: Readout { live.value }
    @Published private(set) var isCapturing = false
    @Published private(set) var developing = 0
    @Published private(set) var message: String?
    @Published private(set) var lastShot: ReviewShot?

    /// ISO and shutter switch to manual independently; one manual and one auto is a priority mode.
    /// Switching one to manual starts it from the current value.
    @Published var manualISO = false {
        didSet {
            guard manualISO != oldValue else { return }
            if manualISO { iso = readout.iso }
            applyExposure()
        }
    }
    @Published var manualShutter = false {
        didSet {
            guard manualShutter != oldValue else { return }
            if manualShutter { duration = readout.duration }
            applyExposure()
        }
    }
    @Published var iso: Double = 100 { didSet { applyExposure() } }
    @Published var duration: Double = 1.0 / 60 { didSet { applyExposure() } }

    /// Locking starts from the current auto value, so the first touch of the slider is a plain lock.
    @Published var manualWhiteBalance = false {
        didSet {
            guard manualWhiteBalance != oldValue else { return }
            if manualWhiteBalance, readout.temperature > 0 {
                temperature = readout.temperature.clamped(WhiteBalance.kelvinRange.lowerBound, WhiteBalance.kelvinRange.upperBound)
            }
            applyWhiteBalance()
        }
    }
    @Published var temperature: Double = 5500 { didSet { applyWhiteBalance() } }

    var whiteBalance: WhiteBalance {
        manualWhiteBalance ? .temperature(temperature) : .auto
    }

    var exposure: Exposure {
        switch (manualISO, manualShutter) {
        case (false, false): .auto
        case (true, true): .manual(iso: iso, duration: duration)
        case (false, true): .shutterPriority(duration: duration)
        case (true, false): .isoPriority(iso: iso)
        }
    }
    @Published var exposureBias: Double = 0 { didSet { service.setExposureBias(exposureBias) } }

    @Published var manualFocus = false {
        didSet {
            guard manualFocus != oldValue else { return }
            if manualFocus { lensPosition = readout.lensPosition }
            applyFocus()
        }
    }
    @Published var lensPosition: Double = 0.5 { didSet { if manualFocus { applyFocus() } } }

    @Published var format = DevelopedFormat(rawValue: UserDefaults.standard.string(forKey: Keys.format) ?? "") ?? .heic {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: Keys.format) }
    }
    @Published var keepRAW = UserDefaults.standard.object(forKey: Keys.keepRAW) as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepRAW, forKey: Keys.keepRAW) }
    }
    /// Lossy quality for HEIC/JPEG. Measured on a 12MP ISO 4000 frame (size / luma PSNR vs lossless):
    /// HEIC .92 → 9.5 MB / 42.8 dB, .88 → 7.2 MB / 41.2 dB, .85 → 4.8 MB / 38.3 dB;
    /// JPEG .95 → 7.9 MB / 40.4 dB, .90 → 7.3 MB / 39.8 dB, .80 → 5.8 MB / 38.3 dB.
    /// From .85 down HEVC smooths fine grain (the codec itself acts as noise reduction); JPEG degrades gradually.
    @Published var quality = UserDefaults.standard.object(forKey: Keys.quality) as? Double ?? 0.88 {
        didSet { UserDefaults.standard.set(quality, forKey: Keys.quality) }
    }

    @Published var saveLocation = UserDefaults.standard.bool(forKey: Keys.saveLocation) {
        didSet {
            UserDefaults.standard.set(saveLocation, forKey: Keys.saveLocation)
            location.setEnabled(saveLocation)
        }
    }

    var outputLabel: String {
        keepRAW ? "RAW+" + format.title : format.title
    }

    private enum Keys {
        static let format = "outputFormat"
        static let keepRAW = "keepRAW"
        static let quality = "quality"
        static let saveLocation = "saveLocation"
    }

    var backLenses: [Lens] { lenses.filter { !$0.isFront } }
    var frontLens: Lens? { lenses.first(where: \.isFront) }

    private var messageTask: Task<Void, Never>?
    private var lastBackLens: Lens?
    private var paused = false

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            phase = .denied
            return
        }
        orientation.start()
        CaptureFiles.purge()
        location.onDenied = { [weak self] in
            self?.saveLocation = false
            self?.show(String(localized: "Location access is off. Allow it in Settings."))
        }
        location.setEnabled(saveLocation)

        lenses = await service.lenses()
        guard let main = backLenses.first(where: \.isMain) ?? lenses.first else {
            phase = .failed(CameraError.noCamera.localizedDescription)
            return
        }
        do {
            state = try await service.select(lensID: main.id)
            phase = .running
            gallery.refresh()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        while !Task.isCancelled {
            if !paused {
                let current = await service.readout()
                if current != live.value { live.value = current }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// While the gallery or a review covers the preview, the camera stops (like the stock camera).
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        service.setPaused(paused)
    }

    func toggleFacing() {
        guard let current = state?.lens else { return }
        if current.isFront {
            if let back = lastBackLens ?? backLenses.first(where: \.isMain) { select(back) }
        } else if let frontLens {
            select(frontLens)
        }
    }

    func select(_ lens: Lens) {
        guard lens != state?.lens else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if let current = state?.lens, !current.isFront { lastBackLens = current }
        Task {
            do {
                state = try await service.select(lensID: lens.id)
                manualISO = false
                manualShutter = false
                manualFocus = false
                service.setExposureBias(exposureBias)
                // The light didn't change with the lens, so a locked white balance carries over.
                service.setWhiteBalance(whiteBalance)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
        manualFocus = false
        // Moving the metering point needs auto exposure; priority modes keep their own metering.
        service.focus(at: devicePoint, meterExposure: exposure == .auto)
    }

    func capture() {
        guard !isCapturing, state?.raw != nil else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let orientation = orientation.orientation
        let format = format
        let keepRAW = keepRAW
        let quality = quality
        let location = saveLocation ? location.usableLocation : nil

        Task {
            let shot: CapturedRAW
            do {
                shot = try await service.capture(rotationAngle: orientation.captureAngle, location: location)
            } catch {
                isCapturing = false
                show(error.localizedDescription)
                return
            }
            isCapturing = false

            developing += 1
            defer { developing -= 1 }
            // Photos copies the DNG in; the temporary file goes either way.
            defer { CaptureFiles.remove(shot.dng) }
            let developed = try? await darkroom.develop(
                dng: shot.dng,
                orientation: shot.orientation,
                as: format,
                quality: quality,
                location: location
            )
            // Cleared on failure so the thumbnail doesn't keep showing the previous shot.
            lastShot = developed.map {
                ReviewShot(
                    data: $0.data,
                    format: $0.format,
                    thumbnail: $0.thumbnail,
                    kind: shot.kind,
                    iso: shot.iso,
                    exposureTime: shot.exposureTime,
                    clippedFraction: shot.clippedFraction
                )
            }
            // A failed development must not lose the shot: keep the DNG regardless of the setting.
            let raw = keepRAW || developed == nil ? shot.dng : nil
            do {
                let savedSeparately = try await PhotoLibrary.save(raw: raw, developed: developed, location: location)
                gallery.refresh()
                // Success is silent, like the stock camera; only say something when the result differs from the settings.
                if developed == nil {
                    show(String(localized: "Development failed, saved the DNG only"))
                } else if savedSeparately {
                    show(String(localized: "Photos didn't accept the RAW pair, saved as two photos"))
                }
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func applyExposure() {
        service.setExposure(exposure)
    }

    private func applyWhiteBalance() {
        service.setWhiteBalance(whiteBalance)
    }

    private func applyFocus() {
        service.setFocus(manualFocus ? lensPosition : nil)
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }
}
