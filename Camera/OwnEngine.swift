import CoreImage
import Foundation
import simd

/// Develops Bayer DNGs without Apple's RAW engine: black and white levels, the as-shot white balance,
/// a linear Malvar-He-Cutler demosaic and the DNG color matrices, nothing else. No tone curve, noise
/// reduction, sharpening, gamut mapping or highlight recovery; highlights clip to white.
///
/// Black is clipped at zero for display without the tint plain clipping leaves (see `rawBlack`): deep,
/// with a neutral floor.
final class OwnEngine {
    private let linearize: CIKernel
    private let demosaic: CIKernel
    private let black: CIKernel
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// `library` is the compiled Metal library holding RawKernels.metal.
    init(library: Data) throws {
        linearize = try CIKernel(functionName: "rawLinearize", fromMetalLibraryData: library)
        demosaic = try CIKernel(functionName: "rawDemosaic", fromMetalLibraryData: library)
        black = try CIKernel(functionName: "rawBlack", fromMetalLibraryData: library)
    }

    /// `vignetteStrength` scales the lens's vignetting correction in stops (0 none, 1 the DNG's full
    /// correction). The result is in the sensor's orientation.
    func develop(_ dng: DNG, pixels: [UInt16], levels: RawLevels, vignetteStrength: Double) -> CIImage? {
        guard pixels.count == dng.width * dng.height,
              let rgb = pipeline(Self.bayer(pixels, width: dng.width, height: dng.height), dng: dng, clip: levels.clip)
        else { return nil }
        let shifts = levels.noise.flatMap { outputNoise(dng, rawNoise: $0) }.map(Self.blackShifts)
            ?? Array(repeating: .zero, count: 4)
        let width = rgb.extent.width, height = rgb.extent.height
        let vignette = dng.vignette ?? Vignette(k: [0, 0, 0, 0, 0], center: CGPoint(x: 0.5, y: 0.5))
        let center = CGPoint(x: vignette.center.x * width, y: vignette.center.y * height)
        let radius = hypot(max(center.x, width - center.x), max(center.y, height - center.y))
        func vector(_ v: SIMD3<Double>) -> CIVector { CIVector(x: v.x, y: v.y, z: v.z) }
        guard let out = black.apply(
            extent: rgb.extent,
            roiCallback: { _, rect in rect },
            arguments: [
                rgb,
                vector(shifts[0]), vector(shifts[1]), vector(shifts[2]), vector(shifts[3]),
                height,
                CIVector(x: vignette.k[0], y: vignette.k[1], z: vignette.k[2], w: vignette.k[3]),
                CGFloat(vignette.k[4]),
                CIVector(x: center.x, y: center.y),
                1 / radius,
                CGFloat(dng.vignette == nil ? 0 : vignetteStrength),
            ]
        ) else { return nil }
        // The DNG crop counts rows from the top.
        let crop = CGRect(x: dng.crop.minX, y: height - dng.crop.maxY, width: dng.crop.width, height: dng.crop.height)
        return out.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// Demosaiced linear sRGB, highlights clipped, black not yet clipped.
    private func pipeline(_ raw: CIImage, dng: DNG, clip: Double) -> CIImage? {
        let height = raw.extent.height
        let gains = 1 / dng.asShotNeutral
        let scale = (0..<4).map { gains[dng.cfa[$0]] / (dng.whiteLevel - dng.blackLevels[$0]) }
        guard let linear = linearize.apply(
            extent: raw.extent,
            roiCallback: { _, rect in rect },
            arguments: [
                raw.samplingNearest(),
                CIVector(values: dng.blackLevels.map { CGFloat($0) }, count: 4),
                CIVector(values: scale.map { CGFloat($0) }, count: 4),
                height,
            ]
        ) else { return nil }
        let rows = (exp2(dng.baselineExposure) * dng.calibration.cameraToSRGB(neutral: dng.asShotNeutral)).transpose
        func vector(_ v: SIMD3<Double>) -> CIVector { CIVector(x: v.x, y: v.y, z: v.z) }
        return demosaic.apply(
            extent: raw.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [
                linear.clampedToExtent().samplingNearest(),
                CIVector(values: dng.cfa.map { CGFloat($0) }, count: 4),
                height,
                vector(rows.columns.0), vector(rows.columns.1), vector(rows.columns.2),
                CGFloat(clip),
            ]
        )
    }

    /// Output noise deviation per channel at each 2×2 position, measured by sending pure raw noise at the
    /// frame's own levels through the same pipeline: the demosaic and color matrix mix the channels' noise
    /// in ways simpler to measure than to derive.
    private func outputNoise(_ dng: DNG, rawNoise: [Double]) -> [SIMD3<Double>]? {
        let size = 128, border = 4
        var random = SplitMix(seed: 0x5EED)
        var patch = [UInt16](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let position = (y & 1) * 2 + (x & 1)
                patch[y * size + x] = UInt16(clamping: Int((dng.blackLevels[position] + rawNoise[position] * random.gaussian()).rounded()))
            }
        }
        guard let noise = pipeline(Self.bayer(patch, width: size, height: size), dng: dng, clip: 1e6) else { return nil }
        var pixels = [Float](repeating: 0, count: size * size * 4)
        context.render(noise, toBitmap: &pixels, rowBytes: size * 16, bounds: noise.extent, format: .RGBAf, colorSpace: nil)
        var sum = [SIMD3<Double>](repeating: .zero, count: 4), squares = sum, count = [Double](repeating: 0, count: 4)
        for y in border..<(size - border) {
            for x in border..<(size - border) {
                let i = (y * size + x) * 4, position = (y & 1) * 2 + (x & 1)
                let v = SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                sum[position] += v
                squares[position] += v * v
                count[position] += 1
            }
        }
        return (0..<4).map { position in
            let mean = sum[position] / count[position]
            return (squares[position] / count[position] - mean * mean).squareRoot()
        }
    }

    /// How far above zero the noise floor of pure black sits, as a share of what plain clipping leaves
    /// (the luminance of 0.399σ per channel). Plain clipping's floor reads as a gray veil in very dark
    /// frames; a quarter keeps black black with sparse grain.
    static let floorShare = 0.25

    /// Per 2×2 position, the shift of each channel that makes zero-mean noise of the given deviations,
    /// clipped at zero, average the same in all three, at `floorShare` of plain clipping's luminance.
    /// Exact for pure black, where the floor shows; above black the noise matters less and less.
    private static func blackShifts(_ noise: [SIMD3<Double>]) -> [SIMD3<Double>] {
        noise.map { sigma in
            // Clipped at zero, zero-mean noise of σ averages 0.399σ.
            let target = floorShare * 0.39894 * simd_dot(SIMD3(0.2126, 0.7152, 0.0722), sigma)
            return SIMD3((0..<3).map { c in sigma[c] > 0 ? sigma[c] * shift(forClippedMean: target / sigma[c]) : 0 })
        }
    }

    /// The shift t (in standard deviations) after which zero-mean normal noise clipped at zero averages
    /// `mean` standard deviations: E[max(0, X − t)] = φ(t) − t·Φ(−t), falling from 0.399 at t = 0 and
    /// negative t raising it. Newton from 0 converges for both signs since the curve is convex.
    private static func shift(forClippedMean mean: Double) -> Double {
        var t = 0.0
        for _ in 0..<60 {
            let tail = 0.5 * erfc(t / 2.squareRoot())
            let f = exp(-t * t / 2) / (2 * Double.pi).squareRoot() - t * tail - mean
            if abs(f) < 1e-10 { break }
            t += f / max(tail, 1e-12)
        }
        return t
    }

    private static func bayer(_ pixels: [UInt16], width: Int, height: Int) -> CIImage {
        CIImage(
            bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 2,
            size: CGSize(width: width, height: height),
            format: .L16,
            colorSpace: nil
        )
    }
}

/// Deterministic normal random numbers for the noise probe (SplitMix64 with Box-Muller).
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        (-2 * log(max(next(), 1e-300))).squareRoot() * cos(2 * .pi * next())
    }
}

/// What the raw values say about the frame's extremes: how strong the noise around black is, and where
/// the sensor clips.
struct RawLevels: Sendable {
    /// Noise standard deviation of each 2×2 position in raw units, from the values below black: with no
    /// signal there, they are noise alone (the RMS of the half below black is σ). nil when hardly any value
    /// is below black, as in a well-exposed frame, where black needs no correction.
    let noise: [Double]?
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
        noise = (0..<4).allSatisfy({ Double(below[$0]) / perPosition > 0.002 })
            ? (0..<4).map { (squares[$0] / Double(below[$0])).squareRoot() }
            : nil

        // A clipped channel piles up at its maximum; a natural maximum is a handful of pixels.
        let saturation = (0..<4)
            .filter { atTop[$0] >= 64 && Double(top[$0]) > dng.whiteLevel / 2 }
            .map { Double(top[$0]) }
            .min() ?? dng.whiteLevel
        let minimumGain = (1 / dng.asShotNeutral).min()
        clip = (saturation - black.max()!) / (dng.whiteLevel - black.max()!) * minimumGain
    }
}
