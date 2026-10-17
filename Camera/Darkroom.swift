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

/// How the DNG becomes the processed photo. None of them adds noise reduction or sharpening.
enum DevelopStyle: String, CaseIterable, Identifiable, Sendable {
    /// `OwnEngine`.
    case own
    /// Apple's engine, linear, with its own black point. It clips raw values at black before white
    /// balance, which leaves noisy shadows blue.
    case linear
    /// Apple's engine with its global tone curve.
    case appleCurve

    var id: Self { self }

    /// Shown in the style picker and written into the photo's file name and metadata.
    var title: String {
        switch self {
        case .own: String(localized: "Own engine")
        case .linear: String(localized: "Linear")
        case .appleCurve: String(localized: "Apple curve")
        }
    }
}

struct DevelopedImage: Sendable {
    let data: Data
    let format: DevelopedFormat
    /// The style actually used, which differs from the chosen one when that can't read the file.
    let style: DevelopStyle
    /// Decoded from the encoded file, so it shows exactly what was saved.
    let thumbnail: CGImage?
}

/// Develops DNGs in the chosen style, with every optional enhancement of the Core Image RAW pipeline off.
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
    private var ownEngine: OwnEngine?

    func develop(
        dng: URL,
        orientation: CGImagePropertyOrientation,
        as format: DevelopedFormat,
        quality: Double,
        location: PhotoLocation?,
        style: DevelopStyle,
        zoom: Double
    ) throws -> DevelopedImage {
        // Digital zoom is a crop of the full raw frame; a file without crop tags develops uncropped.
        let zoom = zoom > 1 && (try? DNG.cropToCenter(dng, zoom: zoom)) != nil ? zoom : 1
        let (output, properties, used) = try render(dng, style: style)
        // Rotate explicitly instead of trusting the DNG's orientation tag.
        let image = output
            .oriented(orientation)
            .settingProperties(Self.metadata(properties, location: location, style: used, zoom: zoom))

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
        return DevelopedImage(data: data, format: format, style: used, thumbnail: Self.thumbnail(of: data))
    }

    /// The developed image in the sensor's orientation, its metadata and the style used. The own engine
    /// reads Bayer data only; front-camera ProRAW goes to `.appleCurve` instead. ProRAW arrives with its
    /// noise already clipped at zero, and in the dark its baseline exposure turns that into a gray floor,
    /// which a linear rendering keeps and Apple's tone curve takes down to black.
    private func render(_ url: URL, style: DevelopStyle) throws -> (CIImage, [String: Any], DevelopStyle) {
        switch style {
        case .linear:
            let (image, properties) = try apple(CIRAWFilter(imageURL: url), boost: 0)
            return (image, properties, style)
        case .appleCurve:
            let (image, properties) = try apple(CIRAWFilter(imageURL: url), boost: 1)
            return (image, properties, style)
        case .own:
            guard case let (dng, pixels)? = bayer(at: url),
                  let engine = ownEngine ?? (try? OwnEngine(library: Self.kernelLibrary())),
                  let image = engine.develop(dng, pixels: pixels, levels: RawLevels(dng, pixels: pixels), vignetteStrength: Self.vignetteStrength),
                  let source = CGImageSourceCreateWithData(dng.data as CFData, nil)
            else { return try render(url, style: .appleCurve) }
            ownEngine = engine
            return (image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:], style)
        }
    }

    private func bayer(at url: URL) -> (DNG, [UInt16])? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let dng = try? DNG(data: data),
              let pixels = try? dng.pixels()
        else { return nil }
        return (dng, pixels)
    }

    /// Apple's engine with noise reduction, sharpening, contrast, detail, moiré reduction and local tone
    /// mapping off. `boost` 0 is a linear response: the default tone curve is what makes Apple's RAW
    /// rendering look blown out.
    private func apple(_ raw: CIRAWFilter?, boost: Float) throws -> (CIImage, [String: Any]) {
        guard let raw else { throw Failure.undecodable }
        raw.boostAmount = boost
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isContrastSupported { raw.contrastAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if raw.isMoireReductionSupported { raw.moireReductionAmount = 0 }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        raw.orientation = .up
        guard let output = raw.outputImage else { throw Failure.undecodable }
        return (output, output.properties)
    }

    /// Share of the lens's vignetting correction the own engine applies, in stops. Full correction lifts
    /// the main camera's corners by 2 EV and their noise fourfold; half leaves a lens-like 1 EV falloff.
    private static let vignetteStrength = 0.5

    private static func kernelLibrary() throws -> Data {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else { throw Failure.undecodable }
        return try Data(contentsOf: url)
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

    /// Pixels are already rotated, so the written orientation tag must be "up". The style goes into the
    /// TIFF Software tag, where editors show what produced the file.
    private static func metadata(_ properties: [String: Any], location: PhotoLocation?, style: DevelopStyle, zoom: Double) -> [String: Any] {
        var props = properties
        if let location { props[kCGImagePropertyGPSDictionary as String] = location.gpsMetadata }
        props[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
        tiff[kCGImagePropertyTIFFSoftware as String] = "Raw (\(style.title))"
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        if zoom > 1 {
            var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifDigitalZoomRatio as String] = zoom
            if let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double {
                exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = Int((focal * zoom).rounded())
            }
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        return props
    }
}
