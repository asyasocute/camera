import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum DevelopedFormat: String, CaseIterable, Identifiable, Sendable {
    case heic, jpeg, png

    var id: Self { self }

    var title: String {
        switch self {
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: "HEIC"
        case .jpeg: "JPG"
        case .png: "PNG"
        }
    }

    var uniformType: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

struct DevelopedImage: Sendable {
    let data: Data
    let format: DevelopedFormat
    /// Decoded from the encoded file, so it shows exactly what was saved.
    let thumbnail: CGImage?
}

/// Develops Bayer DNGs with every optional enhancement of the Core Image RAW pipeline off.
/// Without this, Photos renders the DNG itself and applies its own noise reduction, sharpening and tone curve.
/// Serialized as an actor so back-to-back shots don't hold several full-resolution renders in memory at once.
actor Darkroom {
    enum Failure: LocalizedError {
        case undecodable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .undecodable: String(localized: "Couldn't develop the DNG")
            case .encodingFailed: String(localized: "Couldn't encode the photo")
            }
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    func develop(
        dng: URL,
        orientation: CGImagePropertyOrientation,
        as format: DevelopedFormat,
        quality: Double,
        location: PhotoLocation?
    ) throws -> DevelopedImage {
        guard let raw = CIRAWFilter(imageURL: dng) else {
            throw Failure.undecodable
        }
        // Linear response: the default global tone curve is what makes Apple's RAW rendering look blown out.
        raw.boostAmount = 0
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isContrastSupported { raw.contrastAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if raw.isMoireReductionSupported { raw.moireReductionAmount = 0 }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        // Rotate explicitly instead of trusting the DNG's orientation tag.
        raw.orientation = .up

        guard let output = raw.outputImage else { throw Failure.undecodable }
        let image = output
            .oriented(orientation)
            .settingProperties(Self.metadata(output.properties, location: location))

        let options = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        // 8-bit: measured on an ISO 4000 frame, 10-bit HEIC was 50% larger at the same luma fidelity,
        // and the DNG already carries the full precision for editing.
        let data: Data? = switch format {
        case .heic: context.heifRepresentation(of: image, format: .RGBA8, colorSpace: displayP3, options: options)
        case .jpeg: context.jpegRepresentation(of: image, colorSpace: displayP3, options: options)
        case .png: context.pngRepresentation(of: image, format: .RGBA8, colorSpace: displayP3)
        }
        guard let data else { throw Failure.encodingFailed }
        return DevelopedImage(data: data, format: format, thumbnail: Self.thumbnail(of: data))
    }

    private static func thumbnail(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixels are already rotated, so the written orientation tag must be "up".
    private static func metadata(_ properties: [String: Any], location: PhotoLocation?) -> [String: Any] {
        var props = properties
        if let location { props[kCGImagePropertyGPSDictionary as String] = location.gpsMetadata }
        props[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return props
    }
}
