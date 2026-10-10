import CoreGraphics
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct CleanPrimaryTests {
    @Test func thePrimaryHoldsOnlyTheRenderAndTheMasterTheOriginal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-tests-\(UUID().uuidString)")
        let store = LibraryStore(folder: folder)
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: Date())
        let blurRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 201, upper: 301)],
            annotations: [
                Annotation(id: 1, shape: .blur(rect: blurRect)),
                Annotation(
                    id: 2, shape: .text(origin: CGPoint(x: 10, y: 320), string: "note"),
                    color: .black),
            ])
        try store.saveEdits(primary: primary, original: original, edits: edits)
        let data = try Data(contentsOf: primary)
        #expect(try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data) == nil)
        let written = PixelBuffer(try PNGCodec.decode(data).image)
        #expect(written == PixelBuffer(Renderer.render(original, edits: edits).image))
        // Not one block of the blurred band survives in the primary.
        let source = PixelBuffer(original)
        var same = 0
        for y in 0..<100 {
            for x in 0..<200 where written[x: x, y: y] == source[x: x, y: y] { same += 1 }
        }
        #expect(Double(same) / 20_000 < 0.05)
        let loaded = try store.load(primary)
        #expect(loaded.edits == edits)
        #expect(PixelBuffer(loaded.original) == source)
    }
}
