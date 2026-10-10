import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct LibraryTests {
    let utc = TimeZone(identifier: "UTC")!
    // 2026-10-10 09:43:29 UTC
    let date = Date(timeIntervalSince1970: 1_791_625_409)

    func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-tests-\(UUID().uuidString)")
            .appendingPathComponent("Screenshots")  // deliberately not created
    }

    @Test func namesAreDatedAndPaired() {
        let naming = LibraryNaming(timeZone: utc)
        #expect(naming.baseName(for: date) == "Excerpt 2026-10-10 at 09.43.29")
        #expect(
            LibraryNaming.originalName(forPrimary: "Excerpt 2026-10-10 at 09.43.29.png")
                == "Excerpt 2026-10-10 at 09.43.29 original.png")
        #expect(
            LibraryNaming.primaryName(
                forOriginal: "Excerpt 2026-10-10 at 09.43.29 (2) original.png")
                == "Excerpt 2026-10-10 at 09.43.29 (2).png")
        #expect(LibraryNaming.primaryName(forOriginal: "Excerpt 2026-10-10 at 09.43.29.png") == nil)
    }

    @Test func prefixIsSanitisedForFileNames() {
        func base(_ prefix: String) -> String {
            LibraryNaming(prefix: prefix, timeZone: utc).baseName(for: date)
        }
        #expect(base("a/b:c") == "a-b-c 2026-10-10 at 09.43.29")
        #expect(base("  Shots \n") == "Shots 2026-10-10 at 09.43.29")
        #expect(base("") == "Excerpt 2026-10-10 at 09.43.29")
        #expect(base(" / ") == "- 2026-10-10 at 09.43.29")
        #expect(base("   ") == "Excerpt 2026-10-10 at 09.43.29")
    }

    @Test func saveCaptureCreatesTheFolderAndWritesTheDatedFile() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let url = try store.saveCapture(Fixtures.sheet(width: 60, height: 40), scale: 2, at: date)
        #expect(url.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29.png")
        #expect(try PNGCodec.decode(Data(contentsOf: url)).scale == 2)
    }

    @Test func sameSecondCapturesGetDistinctNames() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let image = Fixtures.sheet(width: 60, height: 40)
        let first = try store.saveCapture(image, scale: 1, at: date)
        let second = try store.saveCapture(image, scale: 1, at: date)
        let third = try store.saveCapture(image, scale: 1, at: date)
        #expect(first.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29.png")
        #expect(second.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29 (2).png")
        #expect(third.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29 (3).png")
    }

    @Test func saveEditsWritesACleanPrimaryAndAMaster() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        try store.saveEdits(primary: primary, original: original, edits: edits)

        let primaryData = try Data(contentsOf: primary)
        #expect(try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: primaryData) == nil)
        let rendered = try PNGCodec.decode(primaryData).image
        #expect(rendered.height == Renderer.render(original, edits: edits).image.height)

        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        let (decoded, decodedEdits) = try MasterFile.decode(Data(contentsOf: master))
        #expect(decodedEdits == edits)
        #expect(PixelBuffer(decoded.image) == PixelBuffer(original))
    }

    @Test func reSavingKeepsTheOriginalPixels() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        try store.saveEdits(
            primary: primary, original: original,
            edits: EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)]))
        let loaded = try store.load(primary)
        let newer = EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 61, upper: 121)])
        try store.saveEdits(primary: primary, original: loaded.original, edits: newer)
        let again = try store.load(primary)
        #expect(again.edits == newer)
        #expect(PixelBuffer(again.original) == PixelBuffer(original))
    }

    @Test func loadResolvesEitherFileAndFlatPrimaries() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let flat = try store.saveCapture(original, scale: 2, at: date)
        let flatLoad = try store.load(flat)
        #expect(flatLoad.edits.scale == 2 && flatLoad.edits.isEmpty)
        #expect(flatLoad.primary == flat)

        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        try store.saveEdits(primary: flat, original: original, edits: edits)
        let master = flat.deletingLastPathComponent()
            .appendingPathComponent(LibraryNaming.originalName(forPrimary: flat.lastPathComponent))
        #expect(try store.load(flat).edits == edits)
        #expect(try store.load(master).edits == edits)
        #expect(try store.load(master).primary == flat)
    }

    func idat(_ png: Data) -> Data {
        var out = Data()
        var i = 8
        let bytes = [UInt8](png)
        while i + 8 <= bytes.count {
            let length =
                Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8
                | Int(bytes[i + 3])
            if String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self) == "IDAT" {
                out.append(contentsOf: bytes[(i + 8)..<(i + 8 + length)])
            }
            i += 12 + length
        }
        return out
    }

    @Test func reSavingLeavesTheMasterPixelBytesIdentical() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try store.saveEdits(
            primary: primary, original: original,
            edits: EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)]))
        let first = try idat(Data(contentsOf: master))
        let newer = EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 61, upper: 121)])
        try store.saveEdits(primary: primary, original: original, edits: newer)
        let second = try Data(contentsOf: master)
        #expect(!first.isEmpty)
        #expect(idat(second) == first)
        #expect(try MasterFile.decode(second).edits == newer)
    }

    @Test func anUnwritableFolderThrows() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "excerpt-block-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let store = LibraryStore(
            folder: blocker.appendingPathComponent("Screenshots"),
            naming: LibraryNaming(timeZone: utc))
        #expect(throws: (any Error).self) {
            try store.saveCapture(Fixtures.sheet(width: 60, height: 40), scale: 1, at: date)
        }
    }
}
