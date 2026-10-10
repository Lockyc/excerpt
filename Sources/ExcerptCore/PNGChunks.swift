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

    struct Chunk {
        let type: String
        let data: [UInt8]
        let range: Range<Int>  // the whole chunk: length, type, data, CRC
    }

    static func chunks(in png: Data) throws -> [Chunk] {
        let bytes = [UInt8](png)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw PNGError.notPNG }
        var chunks: [Chunk] = []
        var offset = 8
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw PNGError.malformed }
            let length = bytes[offset..<(offset + 4)].reduce(0) { Int($0) << 8 | Int($1) }
            let end = offset + 12 + length
            guard end <= bytes.count else { throw PNGError.malformed }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            chunks.append(
                Chunk(
                    type: type, data: Array(bytes[(offset + 8)..<(offset + 8 + length)]),
                    range: offset..<end))
            offset = end
            if type == "IEND" { break }
        }
        return chunks
    }

    public static func chunkTypes(in png: Data) throws -> [String] {
        try chunks(in: png).map(\.type)
    }

    /// Returns `png` with exactly one `iTXt` chunk for `keyword`, holding `text`, before `IEND`.
    public static func settingText(_ text: String, keyword: String, in png: Data) throws -> Data {
        let existing = try chunks(in: png)
        guard let end = existing.last, end.type == "IEND" else { throw PNGError.malformed }
        var out = Data(signature)
        let bytes = [UInt8](png)
        for chunk in existing.dropLast()
        where !(chunk.type == "iTXt" && Self.keyword(of: chunk) == keyword) {
            out.append(contentsOf: bytes[chunk.range])
        }
        // keyword \0, compression flag 0, method 0, empty language \0, empty translation \0, text
        let payload = Array(keyword.utf8) + [0, 0, 0, 0, 0] + Array(text.utf8)
        out.append(contentsOf: makeChunk(type: "iTXt", data: payload))
        out.append(contentsOf: bytes[end.range])
        return out
    }

    public static func text(keyword: String, in png: Data) throws -> String? {
        for chunk in try chunks(in: png)
        where chunk.type == "iTXt" && self.keyword(of: chunk) == keyword {
            var rest = chunk.data.drop(while: { $0 != 0 }).dropFirst()  // past keyword \0
            guard rest.count >= 2, rest.first == 0 else { return nil }  // compressed: not ours
            rest = rest.dropFirst(2)
            rest = rest.drop(while: { $0 != 0 }).dropFirst()  // language
            rest = rest.drop(while: { $0 != 0 }).dropFirst()  // translated keyword
            return String(decoding: rest, as: UTF8.self)
        }
        return nil
    }

    static func keyword(of chunk: Chunk) -> String {
        String(decoding: chunk.data.prefix(while: { $0 != 0 }), as: UTF8.self)
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
