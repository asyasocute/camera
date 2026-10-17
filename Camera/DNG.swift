import CoreGraphics
import Foundation

/// The parts of a DNG the development needs: the Bayer image's metadata and pixels. Supports
/// uncompressed and lossless-JPEG raw data, strips or tiles, either byte order.
struct DNG: Sendable {
    enum Failure: Error {
        case notTIFF
        case noBayerImage
        case unsupported(String)
        case truncated
    }

    let data: Data
    let width: Int
    let height: Int
    /// Color of each position in the 2×2 CFA tile, row-major: 0 red, 1 green, 2 blue.
    let cfa: [Int]
    /// Black level of each position in the 2×2 CFA tile, row-major, in raw units.
    let blackLevels: [Double]
    let whiteLevel: Double
    /// Camera RGB of a neutral under the shot's light, normalized so green is 1.
    let asShotNeutral: SIMD3<Double>
    let baselineExposure: Double
    let calibration: ColorCalibration
    /// Default crop in raw pixel coordinates (top-left origin), within the active area.
    let crop: CGRect
    /// The lens's vignetting correction, which DNGs carry as an opcode applied after demosaicing.
    let vignette: Vignette?

    private let tiff: TIFFFile
    private let raw: TIFFFile.IFD
    private let activeArea: (top: Int, left: Int, bottom: Int, right: Int)

    init(data: Data) throws {
        let tiff = try TIFFFile(data)
        guard let raw = try tiff.findIFD(where: { ifd in
            tiff.ints(ifd[262]).first == 32803 && (tiff.ints(ifd[254]).first ?? 0) & 1 == 0
        }) else { throw Failure.noBayerImage }
        let main = try tiff.ifd(at: tiff.firstIFD)
        // Camera-wide tags belong in IFD 0, but some writers put them next to the raw image.
        func tag(_ t: UInt16) -> TIFFFile.Entry? { raw[t] ?? main[t] }

        self.data = data
        self.tiff = tiff
        self.raw = raw

        guard tiff.ints(raw[277]).first ?? 1 == 1 else { throw Failure.unsupported("samples per pixel") }
        let fullWidth = tiff.ints(raw[256]).first ?? 0
        let fullHeight = tiff.ints(raw[257]).first ?? 0
        let area = tiff.ints(raw[50829])
        activeArea = area.count == 4 ? (area[0], area[1], area[2], area[3]) : (0, 0, fullHeight, fullWidth)
        width = activeArea.right - activeArea.left
        height = activeArea.bottom - activeArea.top
        guard width > 4, height > 4 else { throw Failure.unsupported("size") }

        let repeatDim = tiff.ints(raw[33421])
        let pattern = tiff.ints(raw[33422])
        guard repeatDim.isEmpty || repeatDim == [2, 2], pattern.count == 4, Set(pattern).isSubset(of: [0, 1, 2]) else {
            throw Failure.unsupported("CFA pattern")
        }
        cfa = pattern

        if raw[50715] != nil || raw[50716] != nil { throw Failure.unsupported("black level deltas") }
        let blackDim = tiff.ints(raw[50713])
        let rows = blackDim.count == 2 ? max(blackDim[0], 1) : 1
        let cols = blackDim.count == 2 ? max(blackDim[1], 1) : 1
        var black = tiff.doubles(raw[50714])
        if black.isEmpty { black = [0] }
        guard black.count >= rows * cols else { throw Failure.unsupported("black level") }
        var levels: [Double] = []
        for position in 0..<4 {
            let row = (position / 2) % rows, col = (position % 2) % cols
            levels.append(black[row * cols + col])
        }
        blackLevels = levels
        let bits = tiff.ints(raw[258]).first ?? 16
        whiteLevel = tiff.doubles(raw[50717]).first ?? Double((1 << bits) - 1)

        let neutral = tiff.doubles(tag(50728))
        guard neutral.count == 3, neutral.allSatisfy({ $0 > 0 }) else { throw Failure.unsupported("as-shot neutral") }
        asShotNeutral = SIMD3(neutral[0], neutral[1], neutral[2]) / neutral[1]
        baselineExposure = tiff.doubles(tag(50730)).first ?? 0

        func matrix(_ t: UInt16) -> [Double]? {
            let m = tiff.doubles(tag(t))
            return m.count == 9 ? m : nil
        }
        guard let colorMatrix1 = matrix(50721) else { throw Failure.unsupported("color matrix") }
        let balance = tiff.doubles(tag(50727))
        calibration = ColorCalibration(
            colorMatrix1: colorMatrix1,
            colorMatrix2: matrix(50722),
            forwardMatrix1: matrix(50964),
            forwardMatrix2: matrix(50965),
            cameraCalibration1: matrix(50723),
            cameraCalibration2: matrix(50724),
            analogBalance: balance.count == 3 ? balance : nil,
            illuminant1: tiff.ints(tag(50778)).first ?? 21,
            illuminant2: tiff.ints(tag(50779)).first
        )

        let origin = tiff.doubles(raw[50719]), size = tiff.doubles(raw[50720])
        crop = origin.count == 2 && size.count == 2
            ? CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            : CGRect(x: 0, y: 0, width: width, height: height)

        vignette = (raw[51022] ?? main[51022]).flatMap { Self.vignette(in: tiff.bytes($0)) }
    }

    /// Raw values of the active area, row-major from the top, after the linearization table if any.
    func pixels() throws -> [UInt16] {
        let fullWidth = tiff.ints(raw[256]).first ?? 0
        let fullHeight = tiff.ints(raw[257]).first ?? 0
        let bits = tiff.ints(raw[258]).first ?? 16
        let compression = tiff.ints(raw[259]).first ?? 1
        var full = [UInt16](repeating: 0, count: fullWidth * fullHeight)

        let tileWidth: Int, tileHeight: Int, offsets: [Int], counts: [Int]
        if let w = tiff.ints(raw[322]).first, let h = tiff.ints(raw[323]).first {
            (tileWidth, tileHeight) = (w, h)
            offsets = tiff.ints(raw[324])
            counts = tiff.ints(raw[325])
        } else {
            tileWidth = fullWidth
            tileHeight = tiff.ints(raw[278]).first ?? fullHeight
            offsets = tiff.ints(raw[273])
            counts = tiff.ints(raw[279])
        }
        guard tileWidth > 0, tileHeight > 0, offsets.count == counts.count else { throw Failure.unsupported("layout") }
        let across = (fullWidth + tileWidth - 1) / tileWidth

        try full.withUnsafeMutableBufferPointer { out in
            try data.withUnsafeBytes { (file: UnsafeRawBufferPointer) in
                for (index, (offset, count)) in zip(offsets, counts).enumerated() {
                    guard offset >= 0, count >= 0, offset + count <= file.count else { throw Failure.truncated }
                    let chunk = UnsafeRawBufferPointer(rebasing: file[offset..<(offset + count)])
                    let x0 = (index % across) * tileWidth, y0 = (index / across) * tileHeight
                    let samples: [UInt16]
                    switch (compression, bits) {
                    case (1, 16):
                        samples = (0..<min(count / 2, tileWidth * tileHeight)).map { i in
                            let v = chunk.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                            return tiff.littleEndian ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
                        }
                    case (7, _):
                        samples = try LosslessJPEG.decode(chunk)
                    default:
                        throw Failure.unsupported("compression \(compression), \(bits) bits")
                    }
                    // Samples fill the tile in raster order; tiles at the right and bottom edges are padded.
                    let rowsInTile = min(tileHeight, fullHeight - y0), colsInTile = min(tileWidth, fullWidth - x0)
                    guard rowsInTile > 0, colsInTile > 0 else { continue }
                    for row in 0..<rowsInTile {
                        let source = row * tileWidth
                        guard source < samples.count else { break }
                        let target = (y0 + row) * fullWidth + x0
                        for col in 0..<min(colsInTile, samples.count - source) {
                            out[target + col] = samples[source + col]
                        }
                    }
                }
            }
        }

        let table = tiff.ints(raw[50712])
        if !table.isEmpty {
            let last = table.count - 1
            for i in full.indices { full[i] = UInt16(clamping: table[min(Int(full[i]), last)]) }
        }
        guard width != fullWidth || height != fullHeight else { return full }
        var active = [UInt16](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = (activeArea.top + row) * fullWidth + activeArea.left
            active.replaceSubrange((row * width)..<((row + 1) * width), with: full[source..<(source + width)])
        }
        return active
    }

    /// Narrows the file's default crop to its central 1/`zoom`. This is how digital zoom reaches both the
    /// DNG and the developed photo: the raw data stays complete and viewers show the zoomed framing. The
    /// crop tags are rewritten in place (same type and count), so nothing else in the file moves.
    static func cropToCenter(_ url: URL, zoom: Double) throws {
        var data = try Data(contentsOf: url)
        let tiff = try TIFFFile(data)
        guard let raw = try tiff.findIFD(where: { ifd in
            tiff.ints(ifd[262]).first == 32803 && (tiff.ints(ifd[254]).first ?? 0) & 1 == 0
        }), let originTag = raw[50719], let sizeTag = raw[50720] else { throw Failure.unsupported("default crop") }
        let origin = tiff.doubles(originTag), size = tiff.doubles(sizeTag)
        guard origin.count == 2, size.count == 2, zoom >= 1 else { throw Failure.unsupported("default crop") }

        // Even sizes and offsets keep the crop on whole 2×2 CFA tiles.
        let width = (size[0] / zoom / 2).rounded(.down) * 2, height = (size[1] / zoom / 2).rounded(.down) * 2
        let x = origin[0] + ((size[0] - width) / 4).rounded(.down) * 2
        let y = origin[1] + ((size[1] - height) / 4).rounded(.down) * 2

        func write(_ values: [Double], into entry: TIFFFile.Entry) throws {
            var bytes: [UInt8] = []
            func append(_ v: UInt32, _ count: Int) {
                let all = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                let field = Array(all.suffix(count))
                bytes += tiff.littleEndian ? field.reversed() : field
            }
            for value in values {
                switch entry.type {
                case 3: append(UInt32(value), 2)
                case 4: append(UInt32(value), 4)
                case 5: append(UInt32(value), 4); append(1, 4)
                default: throw Failure.unsupported("default crop type")
                }
            }
            let start = data.startIndex + entry.valueOffset
            data.replaceSubrange(start..<(start + bytes.count), with: bytes)
        }
        try write([x, y], into: originTag)
        try write([width, height], into: sizeTag)
        try data.write(to: url, options: .atomic)
    }

    /// FixVignetteRadial (opcode 3) from an opcode list. Big-endian: count, then per opcode id, version,
    /// flags, parameter size and parameters; for this opcode k0…k4, cx, cy as doubles.
    private static func vignette(in list: Data) -> Vignette? {
        let bytes = [UInt8](list)
        func be32(_ i: Int) -> Int {
            guard i + 4 <= bytes.count else { return 0 }
            return Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        func be64(_ i: Int) -> Double { Double(bitPattern: UInt64(be32(i)) << 32 | UInt64(be32(i + 4))) }
        var offset = 4
        for _ in 0..<min(be32(0), 64) {
            guard offset + 16 <= bytes.count else { break }
            let id = be32(offset), size = be32(offset + 12)
            if id == 3, size >= 56, offset + 16 + 56 <= bytes.count {
                let p = (0..<7).map { be64(offset + 16 + $0 * 8) }
                return Vignette(k: Array(p[0..<5]), center: CGPoint(x: p[5], y: p[6]))
            }
            offset += 16 + size
        }
        return nil
    }
}

/// A DNG's radial vignetting correction: gain 1 + k0 r² + k1 r⁴ + k2 r⁶ + k3 r⁸ + k4 r¹⁰, where r is the
/// distance from the optical center divided by the distance from it to the farthest corner.
struct Vignette: Sendable {
    let k: [Double]
    /// Optical center relative to the image size, from the top left.
    let center: CGPoint

    /// Gain at the farthest corner (r = 1).
    var cornerGain: Double { 1 + k.reduce(0, +) }
}

/// Bare TIFF structure reader.
struct TIFFFile: Sendable {
    struct Entry: Sendable {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Where the value bytes are: inside the entry when they fit in 4 bytes, else elsewhere in the file.
        let valueOffset: Int
        let entryOffset: Int
    }

    struct IFD: Sendable {
        let offset: Int
        let entries: [UInt16: Entry]
        let next: Int

        subscript(tag: UInt16) -> Entry? { entries[tag] }
    }

    let data: Data
    let littleEndian: Bool
    private(set) var firstIFD = 0

    init(_ data: Data) throws {
        guard data.count >= 8 else { throw DNG.Failure.notTIFF }
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw DNG.Failure.notTIFF
        }
        self.data = data
        guard u16(2) == 42 else { throw DNG.Failure.notTIFF }
        firstIFD = Int(u32(4))
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let a = UInt16(data[data.startIndex + offset]), b = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let s = data.startIndex + offset
        let a = UInt32(data[s]), b = UInt32(data[s + 1]), c = UInt32(data[s + 2]), d = UInt32(data[s + 3])
        return littleEndian ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d
    }

    func ifd(at start: Int) throws -> IFD {
        let count = Int(u16(start))
        guard start > 0, start + 2 + count * 12 + 4 <= data.count else { throw DNG.Failure.truncated }
        var entries: [UInt16: Entry] = [:]
        for i in 0..<count {
            let e = start + 2 + i * 12
            let type = u16(e + 2), n = Int(u32(e + 4))
            let size = Self.size(of: type) * n
            let valueOffset = size <= 4 ? e + 8 : Int(u32(e + 8))
            entries[u16(e)] = Entry(tag: u16(e), type: type, count: n, valueOffset: valueOffset, entryOffset: e)
        }
        return IFD(offset: start, entries: entries, next: Int(u32(start + 2 + count * 12)))
    }

    /// Depth-first over the IFD 0 chain and all SubIFDs.
    func findIFD(where match: (IFD) -> Bool) throws -> IFD? {
        var stack = [firstIFD], seen = Set<Int>()
        while let offset = stack.popLast() {
            guard offset > 0, seen.insert(offset).inserted, seen.count < 64 else { continue }
            let ifd = try ifd(at: offset)
            if match(ifd) { return ifd }
            stack.append(ifd.next)
            stack.append(contentsOf: ints(ifd[330]).reversed())
        }
        return nil
    }

    func ints(_ entry: Entry?) -> [Int] {
        guard let e = entry else { return [] }
        return (0..<e.count).compactMap { i in
            switch e.type {
            case 1, 7: Int(data[data.startIndex + e.valueOffset + i])
            case 6: Int(Int8(bitPattern: data[data.startIndex + e.valueOffset + i]))
            case 3: Int(u16(e.valueOffset + i * 2))
            case 8: Int(Int16(bitPattern: u16(e.valueOffset + i * 2)))
            case 4, 13: Int(u32(e.valueOffset + i * 4))
            case 9: Int(Int32(bitPattern: u32(e.valueOffset + i * 4)))
            default: nil
            }
        }
    }

    func doubles(_ entry: Entry?) -> [Double] {
        guard let e = entry else { return [] }
        switch e.type {
        case 5, 10:
            return (0..<e.count).map { i in
                let n = u32(e.valueOffset + i * 8), d = u32(e.valueOffset + i * 8 + 4)
                let num = e.type == 10 ? Double(Int32(bitPattern: n)) : Double(n)
                let den = e.type == 10 ? Double(Int32(bitPattern: d)) : Double(d)
                return den == 0 ? 0 : num / den
            }
        case 11:
            return (0..<e.count).map { Double(Float(bitPattern: u32(e.valueOffset + $0 * 4))) }
        case 12:
            return (0..<e.count).map { i in
                let hi = UInt64(u32(e.valueOffset + i * 8 + (littleEndian ? 4 : 0)))
                let lo = UInt64(u32(e.valueOffset + i * 8 + (littleEndian ? 0 : 4)))
                return Double(bitPattern: hi << 32 | lo)
            }
        default:
            return ints(e).map(Double.init)
        }
    }

    func bytes(_ entry: Entry) -> Data {
        let size = Self.size(of: entry.type) * entry.count
        guard entry.valueOffset >= 0, entry.valueOffset + size <= data.count else { return Data() }
        return data.subdata(in: (data.startIndex + entry.valueOffset)..<(data.startIndex + entry.valueOffset + size))
    }

    static func size(of type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: 1
        }
    }
}
