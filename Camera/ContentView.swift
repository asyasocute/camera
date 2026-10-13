import SwiftUI

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var focusMarker: CGPoint?
    @State private var markerTask: Task<Void, Never>?
    @State private var showsOutputSettings = false
    @State private var reviewing: ReviewShot?
    @State private var showsGallery = false
    @Environment(\.scenePhase) private var scenePhase

    private var isCovered: Bool { reviewing != nil || showsGallery }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .denied:
                UnavailableView("No camera access", systemImage: "camera.fill", message: Text("Allow access in Settings."))
            case .failed(let reason):
                UnavailableView("Camera unavailable", systemImage: "exclamationmark.triangle", message: Text(reason))
            case .starting, .running:
                camera
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await model.start() }
        .fullScreenCover(item: $reviewing) { ShotReview(shot: $0) }
        .fullScreenCover(isPresented: $showsGallery) { GalleryView(store: model.gallery) }
        .onChange(of: isCovered) { covered in model.setPaused(covered) }
        // Picks up photos taken elsewhere and access granted in Settings meanwhile.
        .onChange(of: scenePhase) { phase in if phase == .active { model.gallery.refresh() } }
    }

    private static let topBarHeight: CGFloat = 44
    private static let shutterRowHeight: CGFloat = 100

    /// The preview always gets full width at 3:4. The control panel has one fixed height and goes in the
    /// space below the preview when there is enough (most iPhones), otherwise over the preview's lower
    /// edge (SE, mini), so nothing ever needs scrolling.
    private var camera: some View {
        GeometryReader { geo in
            let previewHeight = geo.size.width * 4 / 3
            let free = geo.size.height - Self.topBarHeight - previewHeight - Self.shutterRowHeight
            let panelBelow = free >= ControlPanel.height
            VStack(spacing: 0) {
                topBar.frame(height: Self.topBarHeight)
                preview(panelOverlaid: !panelBelow)
                    .frame(width: geo.size.width, height: previewHeight)
                if panelBelow {
                    Spacer(minLength: 0)
                    ControlPanel(model: model, live: model.live)
                }
                Spacer(minLength: 0)
                shutterRow.frame(height: Self.shutterRowHeight)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            // Only deviations from plain Bayer RAW are worth a label.
            switch model.state?.raw {
            case .bayer: EmptyView()
            case .proRAW: Text("PRORAW").foregroundStyle(.orange)
            case nil: if model.state != nil { Text("RAW N/A").foregroundStyle(.red) }
            }
            if model.saveLocation {
                LocationBadge(provider: model.location)
            }
            Spacer()
            if model.state?.raw != nil {
                outputButton
            }
        }
        .font(.system(.footnote, design: .monospaced).weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private var outputButton: some View {
        Button { showsOutputSettings = true } label: {
            Text(model.outputLabel)
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsOutputSettings) {
            OutputSettings(model: model)
                .popoverOnPhone()
        }
    }

    // MARK: - Preview

    private func preview(panelOverlaid: Bool) -> some View {
        CameraPreview(
            session: model.service.session,
            lensID: model.state?.lens.id,
            onTap: { devicePoint, viewPoint in
                model.focus(at: devicePoint)
                showMarker(at: viewPoint)
            },
            onHardwareShutter: model.capture,
            hardwareShutterEnabled: !isCovered
        )
        .overlay {
            if let focusMarker {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusMarker)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: focusMarker)
        .overlay {
            Color.black
                .opacity(model.isCapturing ? 0.6 : 0)
                .animation(.easeOut(duration: 0.15), value: model.isCapturing)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if let message = model.message {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.message)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                // Only lenses this phone actually has; a single back camera needs no picker.
                if model.state?.lens.isFront != true, model.backLenses.count > 1 {
                    zoomPicker
                }
                if panelOverlaid {
                    ControlPanel(model: model, live: model.live).background(.black.opacity(0.55))
                }
            }
            .padding(.bottom, panelOverlaid ? 0 : 14)
        }
        .clipped()
    }

    private func showMarker(at point: CGPoint) {
        focusMarker = point
        markerTask?.cancel()
        markerTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            focusMarker = nil
        }
    }

    /// Stock-camera style: the active lens is larger and shows "×".
    private var zoomPicker: some View {
        HStack(spacing: 4) {
            ForEach(model.backLenses) { lens in
                let selected = lens == model.state?.lens
                Button { model.select(lens) } label: {
                    Text(selected ? lens.label : lens.shortLabel)
                        .font(.system(size: selected ? 13 : 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(.black.opacity(0.5), in: Circle())
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.25), in: Capsule())
        .animation(.easeOut(duration: 0.2), value: model.state?.lens)
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack {
            lastShotButton
            Spacer()
            shutter
            Spacer()
            Button(action: model.toggleFacing) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(model.state?.lens.isFront == true ? .yellow : .white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.frontLens == nil)
        }
        .padding(.horizontal, 28)
    }

    private var lastShotButton: some View {
        ThumbnailButton(
            gallery: model.gallery,
            lastShot: model.lastShot?.thumbnail,
            isDeveloping: model.developing > 0,
            onTap: { Task { await openGallery() } }
        )
    }

    /// Like the stock camera, opens the last photo (here with pixel-level zoom), swipeable to earlier ones.
    /// Photos can't be opened on a specific photo, so this is the in-app viewer. Read access is asked
    /// on first use; without it, the last shot from memory.
    private func openGallery() async {
        var canRead = model.gallery.canRead
        if !canRead {
            canRead = await model.gallery.requestAccess()
        }
        if canRead {
            model.gallery.refresh()
            showsGallery = true
        } else if let shot = model.lastShot {
            reviewing = shot
        } else {
            model.show(PhotoLibrary.AccessDenied().localizedDescription)
        }
    }

    private var shutter: some View {
        Button(action: model.capture) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 66, height: 66)
                    .scaleEffect(model.isCapturing ? 0.86 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.state?.raw == nil || model.isCapturing)
        .opacity(model.state?.raw != nil ? 1 : 0.4)
        .animation(.easeOut(duration: 0.1), value: model.isCapturing)
    }
}

/// Observes the gallery itself: changes inside a nested ObservableObject don't reach the parent view.
private struct ThumbnailButton: View {
    @ObservedObject var gallery: GalleryStore
    let lastShot: CGImage?
    let isDeveloping: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            thumbnail
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photos"))
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1))
            if let lastShot {
                Image(decorative: lastShot, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if let latest = gallery.latestThumbnail {
                Image(uiImage: latest)
                    .resizable()
                    .scaledToFill()
            }
            if isDeveloping {
                Color.black.opacity(0.4)
                ProgressView().tint(.white)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Dimmed until there is a recent fix, so it's clear whether the next photo gets a location.
private struct LocationBadge: View {
    @ObservedObject var provider: LocationProvider

    var body: some View {
        Image(systemName: "location.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(provider.usableLocation != nil ? .white : .white.opacity(0.35))
            .accessibilityLabel(Text("Saving location"))
    }
}

private struct OutputSettings: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Format", selection: $model.format) {
                ForEach(DevelopedFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Keep DNG", isOn: $model.keepRAW)
            Toggle("Save location", isOn: $model.saveLocation)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text(model.format == .png ? String(localized: "lossless") : model.quality.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.quality, in: 0.5...1, step: 0.01)
                    .disabled(model.format == .png)
                if let qualityHint {
                    Text(qualityHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if DEBUG
            if let last = model.lastShot {
                Text("Last shot: \(last.format.title), \(last.data.count.formatted(.byteCount(style: .file)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #endif

        }
        .font(.subheadline)
        .tint(.yellow)
        .padding(16)
        .frame(width: 300)
    }

    /// Measured: HEVC smooths grain from 85% down; JPEG at 80% loses as much as HEIC at 85%.
    private var qualityHint: LocalizedStringKey? {
        switch model.format {
        case .heic: "At 85% and below, HEIC starts smoothing grain"
        case .jpeg: "At 80% and below, JPEG starts smoothing grain"
        case .png: nil
        }
    }
}

private enum Control: CaseIterable {
    case ev, iso, shutter, wb, focus
}

/// A row of parameter chips with live values and one slider for the selected chip: a fixed, small
/// height on every iPhone. Dragging the ISO, shutter or focus slider switches that parameter to manual,
/// starting from the current value; the button before the slider returns it to auto.
private struct ControlPanel: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveReadout
    @State private var selected = Control.ev

    static let height: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Control.allCases, id: \.self, content: chip)
            }
            .frame(height: 36)
            HStack(spacing: 10) {
                resetButton
                slider
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: Self.height)
        .tint(.yellow)
        .onChange(of: Control.allCases.map(isEnabled)) { _ in
            if !isEnabled(selected) { selected = Control.allCases.first(where: isEnabled) ?? .ev }
        }
    }

    // MARK: Chips

    private func chip(_ control: Control) -> some View {
        let enabled = isEnabled(control)
        let isSelected = control == selected
        return Button {
            selected = control
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 2) {
                Text(title(of: control))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value(of: control))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isManual(control) ? .yellow : .white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(isSelected ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func title(of control: Control) -> String {
        switch control {
        case .ev: "EV"
        case .iso: "ISO"
        case .shutter: "SHUTTER"
        case .wb: "WB"
        case .focus: "FOCUS"
        }
    }

    private func value(of control: Control) -> String {
        switch control {
        case .ev: model.exposureBias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        case .iso: "\(Int(iso.wrappedValue.rounded()))"
        case .shutter: Format.shutter(duration.wrappedValue)
        case .wb: Format.kelvin(temperature.wrappedValue)
        case .focus: model.manualFocus ? Format.lens(model.lensPosition) : "AF"
        }
    }

    private func isManual(_ control: Control) -> Bool {
        switch control {
        case .ev: model.exposureBias != 0
        case .iso: model.manualISO
        case .shutter: model.manualShutter
        case .wb: model.manualWhiteBalance
        case .focus: model.manualFocus
        }
    }

    private func isEnabled(_ control: Control) -> Bool {
        switch control {
        // Compensation steers whatever is metered; with both ISO and shutter manual nothing is.
        case .ev: !(model.manualISO && model.manualShutter)
        case .iso, .shutter: model.state?.supportsManualExposure == true
        case .wb: model.state?.supportsManualWhiteBalance == true
        case .focus: model.state?.supportsManualFocus == true
        }
    }

    // MARK: Slider row

    private var resetButton: some View {
        let (label, isAuto, reset): (String, Bool, () -> Void) = switch selected {
        case .ev: ("±0", model.exposureBias == 0, { model.exposureBias = 0 })
        case .iso: ("AUTO", !model.manualISO, { model.manualISO = false })
        case .shutter: ("AUTO", !model.manualShutter, { model.manualShutter = false })
        case .wb: ("AUTO", !model.manualWhiteBalance, { model.manualWhiteBalance = false })
        case .focus: ("AF", !model.manualFocus, { model.manualFocus = false })
        }
        return Button(action: reset) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isAuto ? .yellow : .white)
                .frame(width: 54, height: 30)
                .background(.white.opacity(isAuto ? 0.14 : 0.06), in: Capsule())
                .overlay { if isAuto { Capsule().stroke(.yellow.opacity(0.6), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var slider: some View {
        if let range = model.state?.exposureRange {
            switch selected {
            case .ev:
                Slider(value: $model.exposureBias, in: max(-3, range.minBias)...min(3, range.maxBias), step: 1.0 / 3)
            case .iso:
                Slider(value: logScale(iso, range.minISO, range.maxISO))
            case .shutter:
                Slider(value: logScale(duration, range.minDuration, range.maxDuration))
            case .wb:
                Slider(value: miredScale(temperature))
            case .focus:
                Slider(value: lensPosition)
            }
        } else {
            Slider(value: .constant(0.5)).disabled(true)
        }
    }

    /// In auto the binding shows the live value; the first drag switches that parameter alone to manual,
    /// starting from the live value (see CameraModel.manualISO / manualShutter).
    private var iso: Binding<Double> {
        Binding(
            get: { model.manualISO ? model.iso : live.value.iso },
            set: { value in
                if !model.manualISO { model.manualISO = true }
                model.iso = value
            }
        )
    }

    private var duration: Binding<Double> {
        Binding(
            get: { model.manualShutter ? model.duration : live.value.duration },
            set: { value in
                if !model.manualShutter { model.manualShutter = true }
                model.duration = value
            }
        )
    }

    private var temperature: Binding<Double> {
        Binding(
            get: { model.manualWhiteBalance ? model.temperature : live.value.temperature },
            set: { value in
                if !model.manualWhiteBalance { model.manualWhiteBalance = true }
                model.temperature = value
            }
        )
    }

    private var lensPosition: Binding<Double> {
        Binding(
            get: { model.manualFocus ? model.lensPosition : live.value.lensPosition },
            set: { value in
                if !model.manualFocus { model.manualFocus = true }
                model.lensPosition = value
            }
        )
    }

    /// Even steps in mired (1,000,000 / K), which is how differences in color temperature are perceived:
    /// 200 K matters at 2,500 K and barely shows at 9,000 K.
    private func miredScale(_ kelvin: Binding<Double>) -> Binding<Double> {
        let range = WhiteBalance.kelvinRange
        let warm = 1e6 / range.lowerBound, cool = 1e6 / range.upperBound
        return Binding(
            get: { (warm - 1e6 / kelvin.wrappedValue.clamped(range.lowerBound, range.upperBound)) / (warm - cool) },
            set: { kelvin.wrappedValue = 1e6 / (warm - $0 * (warm - cool)) }
        )
    }

    /// Maps a value in lo...hi to 0...1 logarithmically, the natural scale for ISO and shutter stops.
    private func logScale(_ value: Binding<Double>, _ lo: Double, _ hi: Double) -> Binding<Double> {
        Binding(
            get: { lo < hi ? log(value.wrappedValue.clamped(lo, hi) / lo) / log(hi / lo) : 0 },
            set: { value.wrappedValue = lo * pow(hi / lo, $0) }
        )
    }
}

/// ContentUnavailableView is iOS 17+.
struct UnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: Text?

    init(_ title: LocalizedStringKey, systemImage: String, message: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            if let message {
                message
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Before 16.4 a popover on iPhone shows as a sheet.
    @ViewBuilder
    func popoverOnPhone() -> some View {
        if #available(iOS 16.4, *) { presentationCompactAdaptation(.popover) } else { self }
    }
}

enum Format {
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 0.4 { return seconds.formatted(.number.precision(.fractionLength(0...1))) + "s" }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// Rounded to 50 K: finer steps aren't visible and make the number flicker.
    static func kelvin(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return "\(Int((value / 50).rounded()) * 50)K"
    }

    static func lens(_ position: Double) -> String {
        position.formatted(.number.precision(.fractionLength(2)))
    }
}
