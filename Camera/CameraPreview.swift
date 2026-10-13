import AVFoundation
import AVKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Changes on lens switch; the preview connection is recreated and needs its rotation reapplied.
    let lensID: String?
    var onTap: (_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    /// Volume buttons (and Camera Control on devices that have it).
    var onHardwareShutter: () -> Void
    /// Off while something covers the preview, which gives the buttons back their system behavior.
    var hardwareShutterEnabled = true

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        // The view is laid out at exactly 3:4, so fill never crops and leaves no slivers.
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onTap = onTap
        view.onHardwareShutter = onHardwareShutter
        view.setHardwareShutterEnabled(hardwareShutterEnabled)
        view.applyPortraitRotation(for: lensID)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onHardwareShutter: (() -> Void)?
    private var captureEvents: (any UIInteraction)?
    private var rotatedLensID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onHardwareShutter?() }
            }
            addInteraction(interaction)
            captureEvents = interaction
        }
    }

    func setHardwareShutterEnabled(_ enabled: Bool) {
        if #available(iOS 17.2, *) {
            (captureEvents as? AVCaptureEventInteraction)?.isEnabled = enabled
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// SwiftUI updates the view on every render; the rotation only needs setting once per connection.
    func applyPortraitRotation(for lensID: String?) {
        guard lensID != rotatedLensID, let connection = previewLayer.connection else { return }
        connection.applyRotation(90)
        rotatedLensID = lensID
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point), point)
    }
}
