import simd

/// A DNG's color calibration and the camera-to-display math of the DNG specification (chapter 6):
/// matrices interpolated by the white's color temperature, forward matrices when present, otherwise
/// the inverse color matrix with Bradford adaptation to D50.
struct ColorCalibration: Sendable {
    let colorMatrix1: [Double]
    let colorMatrix2: [Double]?
    let forwardMatrix1: [Double]?
    let forwardMatrix2: [Double]?
    let cameraCalibration1: [Double]?
    let cameraCalibration2: [Double]?
    let analogBalance: [Double]?
    /// EXIF light source codes.
    let illuminant1: Int
    let illuminant2: Int?

    /// White-balanced camera RGB to linear sRGB, Core Image's working space. A neutral at green
    /// saturation, (1, 1, 1) after white balance, maps to (1, 1, 1).
    func cameraToSRGB(neutral: SIMD3<Double>) -> simd_double3x3 {
        let balance = analogBalance.map { simd_double3x3(diagonal: SIMD3($0[0], $0[1], $0[2])) } ?? matrix_identity_double3x3

        func weightOfSecond(_ temperature: Double) -> Double {
            guard let illuminant2, colorMatrix2 != nil else { return 0 }
            let t1 = Self.temperature(of: illuminant1), t2 = Self.temperature(of: illuminant2)
            guard t1 != t2 else { return 0 }
            // Linear in inverse temperature between the two calibration illuminants, clamped outside.
            let w = (1 / temperature - 1 / t1) / (1 / t2 - 1 / t1)
            return min(max(w, 0), 1)
        }
        func blend(_ m1: [Double]?, _ m2: [Double]?, _ w: Double) -> simd_double3x3? {
            guard let m1 else { return m2.map(Self.matrix) }
            guard let m2 else { return Self.matrix(m1) }
            return (1 - w) * Self.matrix(m1) + w * Self.matrix(m2)
        }
        func calibration(_ w: Double) -> simd_double3x3 {
            balance * (blend(cameraCalibration1, cameraCalibration2, w) ?? matrix_identity_double3x3)
        }
        func xyzToCamera(_ w: Double) -> simd_double3x3 {
            calibration(w) * Self.matrix(colorMatrix1).blended(with: colorMatrix2.map(Self.matrix), w)
        }

        // The white's chromaticity depends on the matrices, which depend on its temperature: iterate.
        var white = Self.d50xy
        for _ in 0..<30 {
            let xyz = xyzToCamera(weightOfSecond(Self.temperature(of: white))).inverse * neutral
            let next = SIMD2(xyz.x, xyz.y) / (xyz.x + xyz.y + xyz.z)
            let done = simd_distance(next, white) < 1e-7
            white = next
            if done { break }
        }
        let w = weightOfSecond(Self.temperature(of: white))

        let toXYZ: simd_double3x3
        if let forward = blend(forwardMatrix1, forwardMatrix2, w) {
            let referenceNeutral = calibration(w).inverse * neutral
            toXYZ = forward * simd_double3x3(diagonal: 1 / referenceNeutral) * calibration(w).inverse * simd_double3x3(diagonal: neutral)
        } else {
            toXYZ = Self.bradford(from: white, to: Self.d50xy) * xyzToCamera(w).inverse * simd_double3x3(diagonal: neutral)
        }
        let y = (toXYZ * SIMD3(1, 1, 1)).y
        return Self.xyzD50ToSRGB * ((1 / y) * toXYZ)
    }

    private static let d50xy = SIMD2(0.3457, 0.3585)

    /// XYZ (D50) to linear sRGB (D65), Bradford-adapted.
    private static let xyzD50ToSRGB = simd_double3x3(rows: [
        SIMD3(3.1338561, -1.6168667, -0.4906146),
        SIMD3(-0.9787684, 1.9161415, 0.0334540),
        SIMD3(0.0719453, -0.2289914, 1.4052427),
    ])

    private static func matrix(_ m: [Double]) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
    }

    private static func bradford(from source: SIMD2<Double>, to target: SIMD2<Double>) -> simd_double3x3 {
        let m = simd_double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y) }
        return m.inverse * simd_double3x3(diagonal: (m * xyz(target)) / (m * xyz(source))) * m
    }

    /// Correlated color temperature of a chromaticity (McCamy), within a few kelvin over 2000–12500 K.
    private static func temperature(of xy: SIMD2<Double>) -> Double {
        let n = (xy.x - 0.3320) / (0.1858 - xy.y)
        return min(max(449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33, 1000), 50000)
    }

    /// Temperatures the DNG SDK assigns to the EXIF light sources used as calibration illuminants.
    private static func temperature(of illuminant: Int) -> Double {
        switch illuminant {
        case 1, 4, 9: 5500
        case 2, 14: 4150
        case 3: 2850
        case 10: 6500
        case 11: 7500
        case 12: 6430
        case 13: 5000
        case 15: 3450
        case 16: 2940
        case 17: 2856
        case 18: 4874
        case 19: 6774
        case 20: 5503
        case 22: 7504
        case 23: 5003
        case 24: 3200
        default: 6504
        }
    }
}

private extension simd_double3x3 {
    func blended(with other: simd_double3x3?, _ w: Double) -> simd_double3x3 {
        guard let other else { return self }
        return (1 - w) * self + w * other
    }
}
