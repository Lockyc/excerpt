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

extension MasterFile {
    /// Whether `edits` render `original` to `primary` pixel for pixel: the one test of whether a
    /// primary is still its master's render. A primary that fails it was changed since Excerpt
    /// saved it (a redaction drawn over it elsewhere) and is taken as its own pixels, so nothing
    /// the master's original still holds comes back through it. The render's size is compared
    /// from the map before anything is drawn.
    public static func reproduces(
        _ primary: PixelBuffer, from original: CGImage, edits: EditDocument
    ) -> Bool {
        render(original, edits: edits, reproducing: primary) != nil
    }

    /// The render of `original` with `edits` when it is `primary` pixel for pixel, as
    /// `reproduces` judges it; nil otherwise. For a caller that goes on to use the render.
    public static func render(
        _ original: CGImage, edits: EditDocument, reproducing primary: PixelBuffer
    ) -> RenderResult? {
        let map = Renderer.map(width: original.width, height: original.height, edits: edits)
        guard map.renderedWidth == primary.width, map.renderedHeight == primary.height else {
            return nil
        }
        let render = Renderer.render(original, edits: edits)
        return PixelBuffer(render.image) == primary ? render : nil
    }
}
