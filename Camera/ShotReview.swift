import SwiftUI
import UIKit

struct ReviewShot: Identifiable {
    let id = UUID()
    let data: Data
    let format: DevelopedFormat
    let thumbnail: CGImage?
    let kind: RawKind
    let iso: Double?
    let exposureTime: Double?
    let clippedFraction: Double?
}

/// The last shot straight from memory; used when the gallery has no read access to the library.
struct ShotReview: View {
    let shot: ReviewShot
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image, logicalSize: image.size).ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                InfoCapsule(text: info)
                Spacer()
                CloseButton { dismiss() }
            }
            .padding(.horizontal, 16)
        }
        .statusBarHidden()
        .task {
            image = await UIImage(data: shot.data)?.byPreparingForDisplay()
        }
    }

    private var info: String {
        var parts = [shot.format.title, shot.data.count.formatted(.byteCount(style: .file))]
        if shot.kind == .proRAW { parts.insert("ProRAW", at: 0) }
        if let iso = shot.iso { parts.append("ISO \(Int(iso))") }
        if let time = shot.exposureTime { parts.append(Format.shutter(time)) }
        if let clipped = shot.clippedFraction, clipped >= 0.0005 {
            parts.append(String(localized: "clipped \(clipped.formatted(.percent.precision(.fractionLength(1))))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Pinch and double-tap zoom down to single pixels.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    /// Size the image is laid out at. Lower-resolution stand-ins are stretched to it, so swapping in the
    /// full-resolution image later doesn't move or rescale what's on screen.
    let logicalSize: CGSize
    var fullResolution = true

    func makeUIView(context: Context) -> ZoomView { ZoomView(logicalSize: logicalSize) }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.show(image, fullResolution: fullResolution)
    }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize: CGSize = .zero

    init(logicalSize: CGSize) {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.frame = CGRect(origin: .zero, size: logicalSize)
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        contentSize = logicalSize

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: UIImage?, fullResolution: Bool) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // Nearest-neighbour above 1:1 shows actual pixels instead of smoothing the grain away;
        // a lower-resolution stand-in has no real pixels to show, so it keeps smooth scaling.
        imageView.layer.magnificationFilter = fullResolution ? .nearest : .linear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = imageView.bounds.size
        if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 {
            fittedSize = bounds.size
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            minimumZoomScale = fit
            // Logical points equal pixels, so 1 is 3×3 screen pixels per image pixel on a @3x display.
            maximumZoomScale = max(fit, 1)
            zoomScale = fit
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    /// Toggles between fit and 100% (one image pixel per screen pixel) around the tapped point.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale * 1.01 else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let pixelScale = 1 / max(traitCollection.displayScale, 1)
        let target = min(max(pixelScale, minimumZoomScale), maximumZoomScale)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
    }
}
