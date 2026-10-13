import CoreLocation
import Photos

enum PhotoLibrary {
    struct AccessDenied: LocalizedError {
        var errorDescription: String? { String(localized: "No access to Photos. Allow it in Settings.") }
    }

    /// With both files, saves one RAW+processed asset: the DNG must be the primary resource and the
    /// processed file the alternate, the reverse fails with PHPhotosError 3300. If Photos rejects the
    /// pairing anyway (e.g. PNG), both files are kept as separate assets so the shot isn't lost.
    /// The DNG is copied, not moved: if Photos rejects the pair, the fallback still needs the file.
    /// - Returns: true when the pair had to be saved as two separate photos.
    static func save(raw: URL?, developed: DevelopedImage?, location: PhotoLocation?) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw AccessDenied() }

        let base = "RAW_" + Date.now.formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current,
                calendar: .current
            )
        )
        let library = PHPhotoLibrary.shared()

        switch (raw, developed) {
        case let (raw?, developed?):
            do {
                try await library.performChanges {
                    let request = asset(at: location)
                    request.addResource(with: .photo, fileURL: raw, options: rawOptions(base))
                    request.addResource(with: .alternatePhoto, data: developed.data, options: options(base, developed.format))
                }
                return false
            } catch {
                try await library.performChanges {
                    asset(at: location)
                        .addResource(with: .photo, data: developed.data, options: options(base, developed.format))
                    asset(at: location)
                        .addResource(with: .photo, fileURL: raw, options: rawOptions(base))
                }
                return true
            }
        case let (raw?, nil):
            try await library.performChanges {
                asset(at: location).addResource(with: .photo, fileURL: raw, options: rawOptions(base))
            }
        case let (nil, developed?):
            try await library.performChanges {
                asset(at: location)
                    .addResource(with: .photo, data: developed.data, options: options(base, developed.format))
            }
        case (nil, nil):
            break
        }
        return false
    }

    private static func asset(at location: PhotoLocation?) -> PHAssetCreationRequest {
        let request = PHAssetCreationRequest.forAsset()
        request.location = location?.clLocation
        return request
    }

    private static func rawOptions(_ base: String) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = base + ".DNG"
        options.uniformTypeIdentifier = "com.adobe.raw-image"
        return options
    }

    private static func options(_ base: String, _ format: DevelopedFormat) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = base + "." + format.fileExtension
        options.uniformTypeIdentifier = format.uniformType.identifier
        return options
    }
}
