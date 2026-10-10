import Foundation

public enum PNGError: Error, Equatable {
    case notPNG
    case malformed
    case encodeFailed
    case decodeFailed
}

/// Minimal PNG chunk surgery: enough to keep the edit document in an uncompressed `iTXt` chunk.
public enum PNGChunks {
    public static let editsKeyword = "excerpt.edits"
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// What a reader of one keyword's text needs from a PNG, found in one pass.
    public struct TextScan: Sendable {
        /// Whether the file ends in `IEND`. ImageIO decodes a PNG cut short without complaint.
        public let isComplete: Bool
        /// Whether any `iTXt` chunk is keyed so, whether or not its text is readable.
        public let carriesText: Bool
        /// The uncompressed text of the first `iTXt` chunk keyed so; nil when there is none or
        /// it is compressed or malformed.
        public let text: String?
    }

    /// A chunk type as its four bytes, big-endian, so the scan compares integers.
    struct ChunkType: Equatable {
        let raw: UInt32

        init(_ raw: UInt32) { self.raw = raw }
        init(_ name: StaticString) {
            raw = name.withUTF8Buffer { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }

        static let iend = ChunkType("IEND")
        static let itxt = ChunkType("iTXt")

        var name: String {
            String(decoding: withUnsafeBytes(of: raw.bigEndian, Array.init), as: UTF8.self)
        }
    }

    /// Visits every chunk in order with its type and its whole range (length, type, data, CRC)
    /// from the file's start, until `IEND`. Nothing is copied or kept per chunk, so a file of
    /// many or large chunks costs one pass over it. Throws `notPNG` without the signature and
    /// `malformed` when a chunk runs past the end.
    static func forEachChunk(
        in png: Data,
        _ body: (_ type: ChunkType, _ range: Range<Int>, _ bytes: UnsafeRawBufferPointer)
            throws -> Void
    ) throws {
        try png.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 8, bytes.prefix(8).elementsEqual(signature) else {
                throw PNGError.notPNG
            }
            var offset = 8
            while offset < bytes.count {
                guard offset + 12 <= bytes.count else { throw PNGError.malformed }
                let length = Int(
                    UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let type = ChunkType(
                    UInt32(
                        bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                )
                let end = offset + 12 + length
                guard end <= bytes.count else { throw PNGError.malformed }
                try body(type, offset..<end, bytes)
                offset = end
                if type == .iend { break }
            }
        }
    }

    /// Whether the chunk at `range` is an `iTXt` keyed `keyword`: its data up to the first NUL,
    /// or all of it when there is none.
    static func isText(
        _ type: ChunkType, _ range: Range<Int>, keyword: [UInt8], in bytes: UnsafeRawBufferPointer
    ) -> Bool {
        let data = (range.lowerBound + 8)..<(range.upperBound - 4)
        guard type == .itxt, data.count >= keyword.count,
            bytes[data.lowerBound..<(data.lowerBound + keyword.count)].elementsEqual(keyword)
        else { return false }
        return data.count == keyword.count || bytes[data.lowerBound + keyword.count] == 0
    }

    /// The chunk at `range`'s text when it is uncompressed `iTXt`; nil otherwise.
    static func uncompressedText(_ range: Range<Int>, in bytes: UnsafeRawBufferPointer)
        -> String?
    {
        var rest = bytes[(range.lowerBound + 8)..<(range.upperBound - 4)]
        rest = rest.drop(while: { $0 != 0 }).dropFirst()  // past keyword \0
        guard rest.count >= 2, rest.first == 0 else { return nil }  // compressed: not ours
        rest = rest.dropFirst(2)
        rest = rest.drop(while: { $0 != 0 }).dropFirst()  // language
        rest = rest.drop(while: { $0 != 0 }).dropFirst()  // translated keyword
        return String(decoding: rest, as: UTF8.self)
    }

    public static func scan(_ png: Data, keyword: String) throws -> TextScan {
        let key = Array(keyword.utf8)
        var last: ChunkType?
        var carries = false
        var text: String?
        try forEachChunk(in: png) { type, range, bytes in
            last = type
            if !carries, isText(type, range, keyword: key, in: bytes) {
                carries = true
                text = uncompressedText(range, in: bytes)
            }
        }
        return TextScan(isComplete: last == .iend, carriesText: carries, text: text)
    }

    public static func chunkTypes(in png: Data) throws -> [String] {
        var types: [String] = []
        try forEachChunk(in: png) { type, _, _ in types.append(type.name) }
        return types
    }

    /// Returns `png` with exactly one `iTXt` chunk for `keyword`, holding `text`, before `IEND`.
    public static func settingText(_ text: String, keyword: String, in png: Data) throws -> Data {
        let key = Array(keyword.utf8)
        var out = Data(signature)
        var end: Data?
        try forEachChunk(in: png) { type, range, bytes in
            let chunk = Data(bytes[range])
            if type == .iend {
                end = chunk
            } else if !isText(type, range, keyword: key, in: bytes) {
                out.append(chunk)
            }
        }
        guard let end else { throw PNGError.malformed }
        // keyword \0, compression flag 0, method 0, empty language \0, empty translation \0, text
        let payload = key + [0, 0, 0, 0, 0] + Array(text.utf8)
        out.append(contentsOf: makeChunk(type: "iTXt", data: payload))
        out.append(end)
        return out
    }

    public static func text(keyword: String, in png: Data) throws -> String? {
        try scan(png, keyword: keyword).text
    }

    static func makeChunk(type: String, data: [UInt8]) -> [UInt8] {
        let length = UInt32(data.count)
        let typeBytes = Array(type.utf8)
        let crc = crc32(typeBytes + data)
        return bigEndian(length) + typeBytes + data + bigEndian(crc)
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
