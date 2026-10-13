import CoreGraphics
import CoreMotion

/// Physical device orientation from the accelerometer.
/// UIDevice.orientation stays portrait while rotation lock is on, so it can't be used for a camera.
@MainActor
final class OrientationTracker {
    enum Orientation {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

        /// Rotation for back-camera capture connections.
        var captureAngle: CGFloat {
            switch self {
            case .landscapeLeft: 0
            case .portrait: 90
            case .landscapeRight: 180
            case .portraitUpsideDown: 270
            }
        }
    }

    private(set) var orientation: Orientation = .portrait
    private let motion = CMMotionManager()

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            MainActor.assumeIsolated { self.update(x: a.x, y: a.y, z: a.z) }
        }
    }

    /// Gravity in device axes: portrait is y ≈ -1, home-button-right landscape is x ≈ -1.
    /// The margin adds hysteresis around the diagonals; lying flat keeps the last orientation.
    private func update(x: Double, y: Double, z: Double) {
        guard abs(z) < 0.8 else { return }
        let margin = 0.25
        if abs(y) > abs(x) + margin {
            orientation = y < 0 ? .portrait : .portraitUpsideDown
        } else if abs(x) > abs(y) + margin {
            orientation = x < 0 ? .landscapeLeft : .landscapeRight
        }
    }
}
