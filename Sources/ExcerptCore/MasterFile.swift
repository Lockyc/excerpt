import CoreGraphics
import Foundation

/// The private master (`… original.png`): the untouched capture's pixels plus the edit
/// document in an `iTXt` chunk. Never shared; the primary is the clean render.
public enum MasterFile {
    public static func encode(original: CGImage, edits: EditDocument) throws -> Data {
        let png = try PNGCodec.encode(original, scale: edits.scale)
        let json = String(decoding: try edits.encoded(), as: UTF8.self)
        return try PNGChunks.settingText(json, keyword: PNGChunks.editsKeyword, in: png)
    }

    public static func decode(_ data: Data) throws -> (original: DecodedPNG, edits: EditDocument?) {
        let original = try PNGCodec.decode(data)
        guard let json = try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data) else {
            return (original, nil)
        }
        return (original, try EditDocument.decode(Data(json.utf8)))
    }
}
