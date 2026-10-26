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

    @Test func savingKeepsBothFilesCreationDates() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        try store.saveEdits(primary: primary, original: original, edits: edits)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        let born = Date(timeIntervalSince1970: 1_600_000_000)
        for url in [primary, master] {
            try FileManager.default.setAttributes([.creationDate: born], ofItemAtPath: url.path)
        }

        try store.saveEdits(primary: primary, original: original, edits: edits)

        for var url in [primary, master] {
            url.removeAllCachedResourceValues()
            #expect(try url.resourceValues(forKeys: [.creationDateKey]).creationDate == born)
        }
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

    @Test func aForeignOriginalNamedFileOpensAsItself() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let unrelated = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(unrelated, scale: 2, at: date)
        let foreign = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try PNGCodec.encode(Fixtures.sheet(width: 60, height: 40), scale: 1).write(to: foreign)
        let loaded = try store.load(foreign)
        #expect(loaded.primary == foreign)
        #expect(loaded.original.width == 60)
        #expect(loaded.edits.scale == 1 && loaded.edits.cuts.isEmpty)
        // The primary beside it opens as itself too, not through the foreign file.
        #expect(try store.load(primary).original.width == 200)
    }

    @Test func savingBesideAForeignOriginalThrowsAndWritesNothing() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let image = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(image, scale: 2, at: date)
        let foreign = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try PNGCodec.encode(Fixtures.sheet(width: 60, height: 40), scale: 1).write(to: foreign)
        let primaryBefore = try Data(contentsOf: primary)
        let foreignBefore = try Data(contentsOf: foreign)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        #expect(throws: LibraryError.foreignOriginal(foreign)) {
            try store.saveEdits(primary: primary, original: image, edits: edits)
        }
        #expect(try Data(contentsOf: primary) == primaryBefore)
        #expect(try Data(contentsOf: foreign) == foreignBefore)
    }

    @Test func aMasterWithDamagedEditsThrowsOnLoad() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let image = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(image, scale: 2, at: date)
        try store.saveEdits(primary: primary, original: image, edits: EditDocument(scale: 2))
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try PNGChunks.settingText(
            "{broken", keyword: PNGChunks.editsKeyword, in: Data(contentsOf: master)
        ).write(to: master)
        // Opening either file names the master, the file that is bad.
        for opened in [primary, master] {
            do {
                _ = try store.load(opened)
                Issue.record("load should throw")
            } catch let error as MasterUnreadable {
                #expect(error.file == master)
                #expect(error.underlying as? EditDocumentError == .damaged)
            }
        }
    }

    @Test func aMasterOpensWhenItsPrimaryIsGone() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let image = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(image, scale: 2, at: date)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        try store.saveEdits(primary: primary, original: image, edits: edits)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try FileManager.default.removeItem(at: primary)
        let loaded = try store.load(master)
        #expect(loaded.primary == primary)
        #expect(loaded.edits == edits)
        try store.saveEdits(primary: loaded.primary, original: loaded.original, edits: loaded.edits)
        #expect(FileManager.default.fileExists(atPath: primary.path))
    }

    /// A library file cut short (an interrupted copy, a sync placeholder) refuses to open rather
    /// than showing grey rows that a save would make permanent: cut mid-chunk, or whole chunks
    /// with no IEND, as a primary and as a master.
    @Test func aTruncatedFileRefusesToOpen() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let image = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(image, scale: 2, at: date)
        let whole = try Data(contentsOf: primary)
        for cut in [whole.prefix(whole.count / 2), whole.dropLast(12)] {
            try Data(cut).write(to: primary)
            #expect(throws: PNGError.self) { try store.load(primary) }
        }

        try whole.write(to: primary)
        try store.saveEdits(primary: primary, original: image, edits: EditDocument(scale: 2))
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        try Data(Data(contentsOf: master).dropLast(12)).write(to: master)
        #expect(throws: MasterUnreadable.self) { try store.load(master) }
    }

    /// Review focus (privacy): a primary redacted outside Excerpt after saving opens as its own
    /// pixels, so the editor never shows what the redaction covers, and saving it makes the
    /// redacted pixels the master's original rather than restoring the covered ones. The master
    /// opened directly still loads its edits.
    @Test func aPrimaryChangedElsewhereOpensFlatAndSavingKeepsTheChange() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 241, upper: 321)])
        try store.saveEdits(primary: primary, original: original, edits: edits)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))

        let untouched = try store.load(primary)
        #expect(untouched.edits == edits && !untouched.supersedesMaster)
        #expect(PixelBuffer(untouched.original) == PixelBuffer(original))

        var redacted = PixelBuffer(try PNGCodec.decode(Data(contentsOf: primary)).image)
        for y in 20..<60 {
            for x in 10..<190 {
                let i = (y * redacted.width + x) * 4
                redacted.bytes[i..<(i + 4)] = [0, 0, 0, 255]
            }
        }
        try PNGCodec.encode(redacted.makeImage(), scale: 2).write(to: primary)

        let flat = try store.load(primary)
        #expect(flat.supersedesMaster)
        #expect(flat.primary == primary)
        #expect(flat.edits.cuts.isEmpty && flat.edits.scale == 2)
        #expect(PixelBuffer(flat.original) == redacted)
        let direct = try store.load(master)
        #expect(direct.edits == edits && !direct.supersedesMaster)
        #expect(PixelBuffer(direct.original) == PixelBuffer(original))

        let newer = EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 150, upper: 170)])
        try store.saveEdits(
            primary: flat.primary, original: flat.original, edits: newer,
            replacingMaster: flat.supersedesMaster)
        let saved = PixelBuffer(try PNGCodec.decode(Data(contentsOf: primary)).image)
        #expect(saved == PixelBuffer(Renderer.render(redacted.makeImage(), edits: newer).image))
        for y in 20..<60 {
            for x in 10..<140 { #expect(saved[x: x, y: y] == RGBA(r: 0, g: 0, b: 0, a: 255)) }
        }
        let (masterOriginal, masterEdits) = try MasterFile.decode(Data(contentsOf: master))
        #expect(PixelBuffer(masterOriginal.image) == redacted)
        #expect(masterEdits == newer)
        let reopened = try store.load(primary)
        #expect(reopened.edits == newer && !reopened.supersedesMaster)
    }

    /// Every image `load` takes pixels from is admitted first — the master with its edits, then
    /// the primary it is checked against — and a refusal stops the open.
    @Test func loadAdmitsEachImageBeforeReadingIt() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let original = Fixtures.sheet(width: 200, height: 400)
        let primary = try store.saveCapture(original, scale: 2, at: date)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 41, upper: 321)])
        try store.saveEdits(primary: primary, original: original, edits: edits)
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        let rendered = Renderer.render(original, edits: edits).image
        var seen: [String] = []
        _ = try store.load(primary) { file, width, height, admitted in
            seen.append("\(file.lastPathComponent) \(width)x\(height) \(admitted == edits)")
        }
        #expect(
            seen == [
                "\(master.lastPathComponent) 200x400 true",
                "\(primary.lastPathComponent) \(rendered.width)x\(rendered.height) false",
            ])
        struct Refused: Error {}
        #expect(throws: Refused.self) { try store.load(master) { _, _, _, _ in throw Refused() } }
        #expect(throws: Refused.self) {
            try store.load(primary) { file, _, _, _ in if file == primary { throw Refused() } }
        }
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

    @Test func recentCapturesAreTheNewestPrimariesFirst() throws {
        let folder = tempFolder()
        #expect(try LibraryStore(folder: folder).recentCaptures(limit: 5) == [])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = [
            "Excerpt 2026-10-10 at 09.00.00.png", "Excerpt 2026-10-10 at 09.00.00 original.png",
            "Screenshot 2026-10-11 at 10.00.00.png", "notes.txt",
            "Excerpt 2026-10-12 at 11.00.00.png",
        ]
        for (index, name) in names.enumerated() {
            let url = folder.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: date.addingTimeInterval(Double(index) * 60)], ofItemAtPath: url.path
            )
        }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Archive.png"), withIntermediateDirectories: false)
        let store = LibraryStore(folder: folder)
        #expect(
            try store.recentCaptures(limit: 5).map(\.lastPathComponent) == [
                "Excerpt 2026-10-12 at 11.00.00.png", "Screenshot 2026-10-11 at 10.00.00.png",
                "Excerpt 2026-10-10 at 09.00.00.png",
            ])
        #expect(try store.recentCaptures(limit: 1).count == 1)
    }
}

extension LibraryTests {
    @Test func recordingNamesPairAPrimaryWithItsMovMaster() {
        #expect(
            LibraryNaming.recordingMasterName(forBase: "Excerpt 2026-10-10 at 09.43.29 (2)")
                == "Excerpt 2026-10-10 at 09.43.29 (2) original.mov")
        #expect(
            LibraryNaming.recordingBase(forMaster: "Excerpt 2026-10-10 at 09.43.29 original.mov")
                == "Excerpt 2026-10-10 at 09.43.29")
        #expect(LibraryNaming.recordingBase(forMaster: "Excerpt original.png") == nil)
        #expect(LibraryNaming.recordingExtensions == ["gif", "mp4"])
    }

    @Test func reserveRecordingSkipsTakenNames() throws {
        let folder = tempFolder()
        let store = LibraryStore(folder: folder, naming: LibraryNaming(timeZone: utc))
        let first = try store.reserveRecording(at: date)
        #expect(first.base.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29")
        #expect(first.master.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29 original.mov")
        #expect(first.primary(.gif).lastPathComponent == "Excerpt 2026-10-10 at 09.43.29.gif")
        #expect(first.primary(.mp4).lastPathComponent == "Excerpt 2026-10-10 at 09.43.29.mp4")
        for name in [
            "Excerpt 2026-10-10 at 09.43.29.png",
            "Excerpt 2026-10-10 at 09.43.29.gif", "Excerpt 2026-10-10 at 09.43.29.mp4",
            "Excerpt 2026-10-10 at 09.43.29 original.mov",
            "Excerpt 2026-10-10 at 09.43.29 original.png",
        ] {
            let url = folder.appendingPathComponent(name)
            try Data().write(to: url)
            #expect(
                try store.reserveRecording(at: date).base.lastPathComponent
                    == "Excerpt 2026-10-10 at 09.43.29 (2)")
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func aScreenshotAvoidsABaseARecordingHolds() throws {
        let folder = tempFolder()
        let store = LibraryStore(folder: folder, naming: LibraryNaming(timeZone: utc))
        let recording = try store.reserveRecording(at: date)
        try Data().write(to: recording.master)
        let url = try store.saveCapture(Fixtures.sheet(width: 20, height: 20), scale: 1, at: date)
        #expect(url.lastPathComponent == "Excerpt 2026-10-10 at 09.43.29 (2).png")
    }

    @Test func recordingPathsComeFromEitherPrimary() throws {
        let store = LibraryStore(folder: tempFolder(), naming: LibraryNaming(timeZone: utc))
        let reserved = try store.reserveRecording(at: date)
        #expect(store.recordingPaths(forPrimary: reserved.primary(.mp4)) == reserved)
        #expect(store.recordingPaths(forPrimary: reserved.primary(.gif)) == reserved)
        #expect(store.recordingPaths(forPrimary: reserved.master) == nil)
        #expect(
            store.recordingPaths(forPrimary: URL(fileURLWithPath: reserved.base.path + ".png"))
                == nil)
    }

    @Test func recentCapturesListsRecordingsNotTheirMasters() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = [
            "Excerpt 2026-10-10 at 09.00.00.gif", "Excerpt 2026-10-10 at 09.00.00 original.mov",
            "Excerpt 2026-10-11 at 09.00.00.MP4", "Excerpt 2026-10-12 at 09.00.00.png",
            "clip.mov",
        ]
        for (index, name) in names.enumerated() {
            let url = folder.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: date.addingTimeInterval(Double(index) * 60)], ofItemAtPath: url.path
            )
        }
        #expect(
            try LibraryStore(folder: folder).recentCaptures(limit: 10).map(\.lastPathComponent)
                == [
                    "Excerpt 2026-10-12 at 09.00.00.png", "Excerpt 2026-10-11 at 09.00.00.MP4",
                    "Excerpt 2026-10-10 at 09.00.00.gif",
                ])
    }
}
