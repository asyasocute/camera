import CoreImage
import simd

/// Develops Bayer DNGs without Apple's RAW engine: black and white levels, the as-shot white balance,
/// a linear Malvar-He-Cutler demosaic and the DNG color matrices, nothing else. No tone curve, noise
/// reduction, sharpening, gamut mapping or highlight recovery; highlights clip to white.
struct OwnEngine {
    private let linearize: CIKernel
    private let demosaic: CIKernel

    /// `library` is the compiled Metal library holding RawKernels.metal.
    init(library: Data) throws {
        linearize = try CIKernel(functionName: "rawLinearize", fromMetalLibraryData: library)
        demosaic = try CIKernel(functionName: "rawDemosaic", fromMetalLibraryData: library)
    }

    /// `levels` sets the black lift and highlight clip; `vignetteStrength` scales the lens's vignetting
    /// correction in stops (0 none, 1 the DNG's full correction). The result is in the sensor's orientation.
    func develop(_ dng: DNG, pixels: [UInt16], levels: RawLevels, vignetteStrength: Double) -> CIImage? {
        let width = dng.width, height = dng.height
        guard pixels.count == width * height else { return nil }
        let bitmap = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let raw = CIImage(
            bitmapData: bitmap,
            bytesPerRow: width * 2,
            size: CGSize(width: width, height: height),
            format: .L16,
            colorSpace: nil
        )
        let gains = 1 / dng.asShotNeutral
        let scale = (0..<4).map { gains[dng.cfa[$0]] / (dng.whiteLevel - dng.blackLevels[$0]) }
        guard let linear = linearize.apply(
            extent: raw.extent,
            roiCallback: { _, rect in rect },
            arguments: [
                raw.samplingNearest(),
                CIVector(values: dng.blackLevels.map { CGFloat($0) }, count: 4),
                CIVector(values: scale.map { CGFloat($0) }, count: 4),
                CGFloat(height),
            ]
        ) else { return nil }

        let toSRGB = exp2(dng.baselineExposure) * dng.calibration.cameraToSRGB(neutral: dng.asShotNeutral)
        let rows = toSRGB.transpose
        func vector(_ v: SIMD3<Double>) -> CIVector { CIVector(x: v.x, y: v.y, z: v.z) }
        let vignette = dng.vignette ?? Vignette(k: [0, 0, 0, 0, 0], center: CGPoint(x: 0.5, y: 0.5))
        let center = CGPoint(x: vignette.center.x * CGFloat(width), y: vignette.center.y * CGFloat(height))
        let radius = hypot(max(center.x, CGFloat(width) - center.x), max(center.y, CGFloat(height) - center.y))
        guard let rgb = demosaic.apply(
            extent: raw.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [
                linear.clampedToExtent().samplingNearest(),
                CIVector(values: dng.cfa.map { CGFloat($0) }, count: 4),
                CGFloat(height),
                vector(rows.columns.0),
                vector(rows.columns.1),
                vector(rows.columns.2),
                CGFloat(levels.lift),
                CGFloat(levels.clip),
                CIVector(x: vignette.k[0], y: vignette.k[1], z: vignette.k[2], w: vignette.k[3]),
                CGFloat(vignette.k[4]),
                CIVector(x: center.x, y: center.y),
                1 / radius,
                CGFloat(dng.vignette == nil ? 0 : vignetteStrength),
            ]
        ) else { return nil }

        // The DNG crop counts rows from the top.
        let crop = CGRect(x: dng.crop.minX, y: CGFloat(height) - dng.crop.maxY, width: dng.crop.width, height: dng.crop.height)
        return rgb.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }
}

/// What the raw values say about the frame's extremes: how far the noise reaches below black, and where
/// the sensor clips.
struct RawLevels: Sendable {
    /// White-balanced units (1 = green saturation per the DNG) that keep the noise around black above
    /// zero for two standard deviations in every channel; there the clipped tail moves the mean by under
    /// 1% of σ. Zero when hardly any value is below black, as in a well-exposed frame.
    let lift: Double
    /// White-balanced level where the first channel saturates. iPhone DNGs declare a white level of 4095
    /// while their data clips lower, at 3567, so it's found from the pile-up of values at the top.
    let clip: Double

    init(_ dng: DNG, pixels: [UInt16]) {
        var squares = [Double](repeating: 0, count: 4)
        var below = [Int](repeating: 0, count: 4)
        var top = [UInt16](repeating: 0, count: 4)
        var atTop = [Int](repeating: 0, count: 4)
        let black = dng.blackLevels
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<dng.height {
                let row = y * dng.width, positions = (y & 1) * 2
                for x in 0..<dng.width {
                    let position = positions + (x & 1)
                    let v = p[row + x]
                    let d = black[position] - Double(v)
                    if d > 0 {
                        squares[position] += d * d
                        below[position] += 1
                    }
                    if v > top[position] {
                        top[position] = v
                        atTop[position] = 1
                    } else if v == top[position] {
                        atTop[position] += 1
                    }
                }
            }
        }
        let perPosition = Double(dng.width * dng.height) / 4
        var lift = 0.0
        for position in 0..<4 where Double(below[position]) / perPosition > 0.002 {
            // RMS of the part below black: σ for the half-normal of a zero-signal area.
            let sigma = (squares[position] / Double(below[position])).squareRoot()
            let gain = 1 / dng.asShotNeutral[dng.cfa[position]]
            lift = max(lift, 2 * sigma * gain / (dng.whiteLevel - black[position]))
        }
        self.lift = lift

        // A clipped channel piles up at its maximum; a natural maximum is a handful of pixels.
        let saturation = (0..<4)
            .filter { atTop[$0] >= 64 && Double(top[$0]) > dng.whiteLevel / 2 }
            .map { Double(top[$0]) }
            .min() ?? dng.whiteLevel
        let minimumGain = (1 / dng.asShotNeutral).min()
        clip = (saturation - black.max()!) / (dng.whiteLevel - black.max()!) * minimumGain
    }
}
