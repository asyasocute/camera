import CoreLocation
import ImageIO

/// A location fix as plain values, so it can travel to the capture and save code on other threads.
struct PhotoLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        timestamp = location.timestamp
    }

    /// A fix older than two minutes may be somewhere else entirely; better no location than a wrong one.
    var isUsable: Bool {
        horizontalAccuracy >= 0 && timestamp.timeIntervalSinceNow > -120
    }

    var clLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: timestamp
        )
    }

    /// EXIF GPS block (kCGImagePropertyGPSDictionary): unsigned values with N/S, E/W refs, UTC time.
    var gpsMetadata: [String: Any] {
        let utc = TimeZone(identifier: "UTC")!
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = utc
            formatter.dateFormat = pattern
            return formatter.string(from: timestamp)
        }
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSHPositioningError as String: horizontalAccuracy,
            kCGImagePropertyGPSDateStamp as String: format("yyyy:MM:dd"),
            kCGImagePropertyGPSTimeStamp as String: format("HH:mm:ss.SS"),
        ]
        if verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return gps
    }
}

/// Keeps a recent fix while "Save location" is on. Asks for when-in-use access the first time it's enabled.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var current: PhotoLocation?
    /// Called when the user has denied access while saving location is on.
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private var enabled = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var usableLocation: PhotoLocation? {
        current.flatMap { $0.isUsable ? $0 : nil }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        update()
    }

    private func update() {
        switch manager.authorizationStatus {
        case .notDetermined:
            if enabled { manager.requestWhenInUseAuthorization() }
        case .authorizedWhenInUse, .authorizedAlways:
            if enabled {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
                current = nil
            }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            current = nil
            if enabled { onDenied?() }
        @unknown default:
            break
        }
    }

    // The manager is created on the main thread, so it calls its delegate there.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { update() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = PhotoLocation(last)
        MainActor.assumeIsolated { current = fix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
