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
    /// Digital zoom shows the frame's center enlarged. The device itself stays at 1×: Bayer RAW requires it.
    var zoom: CGFloat = 1

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
        view.setZoom(zoom)
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
                // On press, like the on-screen shutter; waiting for the release adds the press's length.
                if event.phase == .began { self?.onHardwareShutter?() }
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

    func setZoom(_ zoom: CGFloat) {
        guard transform.a != zoom else { return }
        UIView.animate(withDuration: 0.2) { self.transform = CGAffineTransform(scaleX: zoom, y: zoom) }
    }

    /// The point is in the view's own coordinates, which the zoom scales about the center; the second
    /// argument is where the tap appears in the unscaled frame.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let zoom = transform.a, mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let shown = CGPoint(x: mid.x + (point.x - mid.x) * zoom, y: mid.y + (point.y - mid.y) * zoom)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point), shown)
    }
}
