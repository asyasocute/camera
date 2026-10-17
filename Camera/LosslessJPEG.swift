import Foundation

/// Lossless JPEG (ITU T.81, process 14, SOF3), the compression of most compressed DNGs.
enum LosslessJPEG {
    enum Failure: Error {
        case malformed(String)
    }

    /// Codes up to this length resolve with one table lookup; longer ones (rare) walk the code lengths.
    private static let lookupBits = 10

    private struct Table {
        /// `length << 8 | symbol` for every code prefix of `lookupBits` bits; 0 when the code is longer.
        var lookup = [UInt16](repeating: 0, count: 1 << lookupBits)
        var maxCode = [Int32](repeating: -1, count: 18)
        var valueOffset = [Int32](repeating: 0, count: 18)
        var symbols = [UInt8](repeating: 0, count: 256)

        init(counts: [Int], symbols list: [UInt8]) throws {
            guard list.count <= 256 else { throw Failure.malformed("Huffman table") }
            symbols.replaceSubrange(0..<list.count, with: list)
            var code = 0, k = 0
            for length in 1...16 {
                let n = counts[length - 1]
                if n > 0 {
                    valueOffset[length] = Int32(k - code)
                    for _ in 0..<n {
                        guard k < list.count else { throw Failure.malformed("Huffman table") }
                        if length <= lookupBits {
                            let shift = lookupBits - length
                            for prefix in (code << shift)..<((code + 1) << shift) {
                                lookup[prefix] = UInt16(length << 8) | UInt16(list[k])
                            }
                        }
                        code += 1
                        k += 1
                    }
                    maxCode[length] = Int32(code - 1)
                }
                code <<= 1
            }
        }
    }

    /// Samples in raster order, components interleaved, at full precision (point transform undone).
    static func decode(_ bytes: UnsafeRawBufferPointer) throws -> [UInt16] {
        func byte(_ i: Int) throws -> Int {
            guard i >= 0, i < bytes.count else { throw Failure.malformed("truncated") }
            return Int(bytes[i])
        }
        func u16(_ i: Int) throws -> Int { try byte(i) << 8 | byte(i + 1) }

        guard try u16(0) == 0xFFD8 else { throw Failure.malformed("no SOI") }
        var tables: [Int: Table] = [:]
        var precision = 0, width = 0, height = 0, components = 0
        var pos = 2
        while pos < bytes.count {
            guard try byte(pos) == 0xFF else { throw Failure.malformed("expected a marker") }
            var marker = try byte(pos + 1)
            pos += 2
            while marker == 0xFF {
                marker = try byte(pos)
                pos += 1
            }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) { continue }
            if marker == 0xD9 { break }
            let end = try pos + u16(pos)
            let segment = pos + 2
            guard end <= bytes.count else { throw Failure.malformed("truncated segment") }
            switch marker {
            case 0xC4:
                var p = segment
                while p < end {
                    let id = try byte(p) & 0x0F
                    let counts = try (0..<16).map { try byte(p + 1 + $0) }
                    let total = counts.reduce(0, +)
                    let symbols = try (0..<total).map { UInt8(try byte(p + 17 + $0)) }
                    tables[id] = try Table(counts: counts, symbols: symbols)
                    p += 17 + total
                }
            case 0xC3:
                precision = try byte(segment)
                height = try u16(segment + 1)
                width = try u16(segment + 3)
                components = try byte(segment + 5)
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                throw Failure.malformed("not lossless JPEG")
            case 0xDD:
                guard try u16(segment) == 0 else { throw Failure.malformed("restart intervals") }
            case 0xDA:
                let n = try byte(segment)
                guard n == components, n > 0, n <= 4, width > 0, height > 0, (2...16).contains(precision) else {
                    throw Failure.malformed("scan header")
                }
                let scanTables = try (0..<n).map { i -> Table in
                    guard let table = tables[try byte(segment + 2 + i * 2) >> 4] else { throw Failure.malformed("missing table") }
                    return table
                }
                let predictor = try byte(segment + 1 + n * 2)
                let pointTransform = try byte(segment + 3 + n * 2) & 0x0F
                guard (1...7).contains(predictor), pointTransform < precision else { throw Failure.malformed("predictor") }
                return try decodeScan(
                    bytes, from: end, width: width, height: height, components: n,
                    precision: precision, predictor: predictor, pointTransform: pointTransform, tables: scanTables
                )
            default:
                break
            }
            pos = end
        }
        throw Failure.malformed("no scan")
    }

    private static func decodeScan(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int,
        width: Int,
        height: Int,
        components: Int,
        precision: Int,
        predictor: Int,
        pointTransform: Int,
        tables: [Table]
    ) throws -> [UInt16] {
        // Flattened per-component tables, so the hot loop indexes plain buffers.
        let lookup = tables.flatMap(\.lookup)
        let maxCode = tables.flatMap(\.maxCode)
        let valueOffset = tables.flatMap(\.valueOffset)
        let symbols = tables.flatMap(\.symbols)
        let lookupSize = 1 << lookupBits
        let rowLength = width * components
        var out = [UInt16](repeating: 0, count: rowLength * height)

        var buffer: UInt64 = 0
        var bits = 0
        var p = start
        let end = bytes.count
        // Entropy-coded bytes: 0xFF is followed by a stuffed 0x00; any other byte after 0xFF is a marker,
        // after which the reader feeds zeros.
        func refill() {
            while bits <= 56 {
                var b: UInt64 = 0
                if p < end {
                    let v = bytes[p]
                    if v != 0xFF {
                        b = UInt64(v)
                        p += 1
                    } else if p + 1 < end, bytes[p + 1] == 0 {
                        b = 0xFF
                        p += 2
                    }
                }
                buffer |= b << UInt64(56 - bits)
                bits += 8
            }
        }

        try lookup.withUnsafeBufferPointer { lookup in
            try maxCode.withUnsafeBufferPointer { maxCode in
                try valueOffset.withUnsafeBufferPointer { valueOffset in
                    try symbols.withUnsafeBufferPointer { symbols in
                        try out.withUnsafeMutableBufferPointer { o in
                            func difference(_ component: Int) throws -> Int {
                                if bits < 32 { refill() }
                                let entry = lookup[component * lookupSize + Int(buffer >> UInt64(64 - lookupBits))]
                                var length = Int(entry >> 8)
                                var symbol = Int(entry & 0xFF)
                                if length == 0 {
                                    length = lookupBits + 1
                                    while true {
                                        guard length <= 16 else { throw Failure.malformed("bad Huffman code") }
                                        let code = Int32(truncatingIfNeeded: buffer >> UInt64(64 - length))
                                        if code <= maxCode[component * 18 + length] {
                                            symbol = Int(symbols[component * 256 + Int(code + valueOffset[component * 18 + length])])
                                            break
                                        }
                                        length += 1
                                    }
                                }
                                buffer <<= UInt64(length)
                                bits -= length
                                switch symbol {
                                case 0: return 0
                                case 16: return 32768
                                case 1...15:
                                    if bits < 16 { refill() }
                                    let v = Int(buffer >> UInt64(64 - symbol))
                                    buffer <<= UInt64(symbol)
                                    bits -= symbol
                                    return v < 1 << (symbol - 1) ? v - (1 << symbol) + 1 : v
                                default:
                                    throw Failure.malformed("bad difference category")
                                }
                            }

                            let initial = 1 << (precision - pointTransform - 1)
                            for y in 0..<height {
                                let row = y * rowLength
                                for x in 0..<width {
                                    for c in 0..<components {
                                        let i = row + x * components + c
                                        let prediction: Int
                                        if y == 0 {
                                            prediction = x == 0 ? initial : Int(o[i - components])
                                        } else if x == 0 {
                                            prediction = Int(o[i - rowLength])
                                        } else {
                                            let a = Int(o[i - components]), b = Int(o[i - rowLength])
                                            let d = Int(o[i - rowLength - components])
                                            switch predictor {
                                            case 1: prediction = a
                                            case 2: prediction = b
                                            case 3: prediction = d
                                            case 4: prediction = a + b - d
                                            case 5: prediction = a + ((b - d) >> 1)
                                            case 6: prediction = b + ((a - d) >> 1)
                                            default: prediction = (a + b) >> 1
                                            }
                                        }
                                        o[i] = UInt16(truncatingIfNeeded: prediction + (try difference(c)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if pointTransform > 0 {
            for i in out.indices { out[i] <<= UInt16(pointTransform) }
        }
        return out
    }
}
