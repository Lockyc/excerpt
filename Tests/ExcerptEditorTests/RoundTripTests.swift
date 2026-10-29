import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptEditor

/// The Phase 2 gate, without the window: cut a spreadsheet capture, reopen it from the library,
/// adjust the cut — through the same model calls the canvas makes.
@Suite struct RoundTripTests {
    func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-editor-tests-\(UUID().uuidString)")
    }

    func sheet() -> CGImage { Fixtures.sheet(width: 360, height: 400) }

    func drag(_ m: EditorModel, _ from: CGPoint, _ to: CGPoint) {
        let map = Renderer.renderBase(m.original, edits: m.baseDocument).map
        m.mouseDown(Pointer(rendered: from, map: map), map: map)
        m.mouseUp(Pointer(rendered: to, map: map), map: map, snap: true)
    }

    /// Saves, then checks the primary is clean (no iTXt chunk, where edits or salt would live)
    /// and returns its height.
    func save(_ m: EditorModel, _ store: LibraryStore, _ primary: URL) throws -> Int {
        try store.saveEdits(primary: primary, original: m.original, edits: m.document)
        m.markSaved(m.document)
        let data = try Data(contentsOf: primary)
        #expect(try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data) == nil)
        #expect(try !PNGChunks.chunkTypes(in: data).contains("iTXt"))
        return try PNGCodec.decode(data).image.height
    }

    @Test func cutReopenAndAdjust() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(folder: directory)
        let primary = try store.saveCapture(sheet(), scale: 1, at: Date())

        // Cut rows 40..<160 (the drag snaps to the gridlines) and save.
        let first = try store.load(primary)
        let editing = EditorModel(original: first.original, document: first.edits)
        editing.tool = .cut
        drag(editing, CGPoint(x: 100, y: 45), CGPoint(x: 100, y: 155))
        #expect(editing.document.cuts == [Cut(axis: .horizontal, lower: 40, upper: 160)])
        #expect(editing.isDirty)
        let firstHeight = try save(editing, store, primary)
        #expect(!editing.isDirty)
        #expect(firstHeight < 400)

        // Reopen from the library: the cut is back, adjustable, over the untouched original.
        let reopened = try store.load(primary)
        #expect(reopened.edits.cuts == [Cut(axis: .horizontal, lower: 40, upper: 160)])
        #expect(PixelBuffer(reopened.original) == PixelBuffer(sheet()))
        let adjusting = EditorModel(original: reopened.original, document: reopened.edits)
        adjusting.tool = .select
        drag(adjusting, CGPoint(x: 100, y: 48), CGPoint(x: 100, y: 48))  // select the seam
        #expect(adjusting.selection == .seam(.horizontal, 40..<160))
        // Drag the after handle (the gap's end, rendered 58) up 37px: snaps to row 120.
        drag(adjusting, CGPoint(x: 100, y: 58), CGPoint(x: 100, y: 21))
        #expect(adjusting.document.cuts == [Cut(axis: .horizontal, lower: 40, upper: 120)])
        #expect(adjusting.isDirty)
        let secondHeight = try save(adjusting, store, primary)
        #expect(!adjusting.isDirty)
        #expect(secondHeight == firstHeight + 40 && secondHeight < 400)

        let last = try store.load(primary)
        #expect(last.edits.cuts == [Cut(axis: .horizontal, lower: 40, upper: 120)])
        #expect(PixelBuffer(last.original) == PixelBuffer(sheet()))
        let master = primary.deletingLastPathComponent().appendingPathComponent(
            LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        #expect(try MasterFile.decode(Data(contentsOf: master)).edits == last.edits)
        let written = try PNGCodec.decode(Data(contentsOf: primary)).image
        #expect(
            PixelBuffer(written)
                == PixelBuffer(Renderer.render(last.original, edits: last.edits).image))
    }

    @Test func aPrimaryWhoseMasterIsGoneOpensFlat() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(folder: directory)
        let original = sheet()
        let primary = try store.saveCapture(original, scale: 2, at: Date())
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 40, upper: 160)], salt: 7)
        try store.saveEdits(primary: primary, original: original, edits: edits)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try FileManager.default.removeItem(at: master)

        let flat = try store.load(primary)
        #expect(flat.edits == EditDocument(scale: 2, salt: flat.edits.salt))
        #expect(flat.original.height == Renderer.render(original, edits: edits).image.height)
        // Editing it again makes a new master from the flat render.
        let m = EditorModel(original: flat.original, document: flat.edits)
        m.apply { $0.crop = PixelRect(x: 0, y: 0, width: 300, height: 100) }
        try store.saveEdits(primary: primary, original: m.original, edits: m.document)
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(
            try store.load(primary).edits.crop == PixelRect(x: 0, y: 0, width: 300, height: 100))
    }

    @Test func aForeignPNGOpensFlatAndSavesBesideItself() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("diagram.png")
        try PNGCodec.encode(Fixtures.sheet(width: 120, height: 80), scale: 1).write(to: foreign)

        // Any LibraryStore opens a file by its own folder.
        let other = folder()
        defer { try? FileManager.default.removeItem(at: other) }
        let store = LibraryStore(folder: other)
        let loaded = try store.load(foreign)
        #expect(loaded.primary == foreign)
        #expect(loaded.edits == EditDocument(scale: 1, salt: loaded.edits.salt))
        let edits = EditDocument(
            scale: 1,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 0, width: 60, height: 40)))
            ], salt: 9)
        try store.saveEdits(primary: foreign, original: loaded.original, edits: edits)
        let master = directory.appendingPathComponent("diagram original.png")
        #expect(try MasterFile.decode(Data(contentsOf: master)).edits == edits)
        #expect(
            try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: Data(contentsOf: foreign))
                == nil)
    }

    @Test func aFileThatIsNotAPNGFailsToOpen() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bogus = directory.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: bogus)
        #expect(throws: PNGError.notPNG) { try LibraryStore(folder: directory).load(bogus) }
    }
}
