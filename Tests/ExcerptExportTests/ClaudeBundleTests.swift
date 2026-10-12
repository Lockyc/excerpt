import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptExport

@Suite struct ClaudeBundleTests {
    static func cache() -> ClaudeCache {
        ClaudeCache(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("excerpt-claude-\(UUID().uuidString)"))
    }

    /// A primary called `name` in a captures folder; nothing need exist there.
    static func primary(_ name: String, in folder: String = "/captures") -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
    }

    /// The roadmap gate's shape: a 10,000-point capture at 2× becomes eight 1× tiles and the
    /// text, with the cut written in.
    @Test func aTallCaptureBecomesOneTimesTilesAndText() throws {
        let name = "Excerpt 2026-10-10 at 09.43.29"
        let original = ColourWords.page(
            width: 100, height: 20_000, words: ["alpha": (20, 100), "omega": (20, 19_800)])
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 9_000, upper: 9_036)], salt: 7)
        let bundle = try ClaudeBundle.write(
            original: original, edits: edits,
            primary: ClaudeBundleTests.primary(name),
            cache: Self.cache(), recognizer: ColourWords())
        #expect(
            bundle.folder.lastPathComponent
                == ClaudeCache.folderName(for: ClaudeBundleTests.primary(name)))
        #expect(bundle.folder.lastPathComponent.hasPrefix("Excerpt-2026-10-10-at-09.43.29-"))
        // 20,000 rows less 36 cut plus the 36-pixel seam is 20,000 pixels: 10,000 points.
        #expect(bundle.tiles.count == 8)
        #expect(bundle.tiles.first?.lastPathComponent == "tile-1-of-8.png")
        for tile in bundle.tiles {
            let decoded = try PNGCodec.decode(Data(contentsOf: tile))
            #expect(decoded.image.width == 50)
            #expect(decoded.image.height == Tiling.tileLength)
            #expect(decoded.scale == 1)
        }
        #expect(bundle.text == "alpha\n[⋯ 18 px hidden]\nomega\n")
        #expect(try String(contentsOf: bundle.textFile, encoding: .utf8) == bundle.text)
        #expect(
            bundle.references.split(separator: " ").map(String.init)
                == (bundle.tiles + [bundle.textFile]).map { "@" + $0.path })
        #expect(bundle.references.hasSuffix(".md "))
    }

    /// Review focus: a 1× capture and a 2× capture of the same content give the same tiles.
    @Test func aOneTimesSourceIsNotScaled() throws {
        let original = Fixtures.sheet(width: 500, height: 1_000)
        let bundle = try ClaudeBundle.write(
            original: original, edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("one"), cache: Self.cache(),
            recognizer: ColourWords())
        #expect(bundle.tiles.count == 1)
        let tile = try PNGCodec.decode(Data(contentsOf: bundle.tiles[0])).image
        #expect(PixelBuffer(tile) == PixelBuffer(original))
    }

    @Test func sameNamedCapturesInTwoFoldersKeepTheirOwnBundles() throws {
        let cache = Self.cache()
        let tall = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 4_000), edits: EditDocument(scale: 1),
            primary: Self.primary("shot", in: "/a"), cache: cache, recognizer: ColourWords())
        let short = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 400), edits: EditDocument(scale: 1),
            primary: Self.primary("shot", in: "/b"), cache: cache, recognizer: ColourWords())
        #expect(tall.folder != short.folder)
        #expect(tall.tiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(tall.tiles.count == 3 && short.tiles.count == 1)
    }

    @Test func writingAgainReplacesTheFolder() throws {
        let cache = Self.cache()
        let tall = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 4_000), edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("same"), cache: cache, recognizer: ColourWords())
        #expect(tall.tiles.count == 3)
        let short = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 400), edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("same"), cache: cache, recognizer: ColourWords())
        let left = try FileManager.default.contentsOfDirectory(atPath: short.folder.path).sorted()
        #expect(left == ["text.md", "tile-1-of-1.png"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: cache.root.path)
        #expect(siblings == [short.folder.lastPathComponent])
    }

    /// Review focus: an unwritable cache fails with the folder named, leaving nothing behind.
    @Test func anUnwritableCacheFailsNamingTheFolder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-not-a-folder-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        let cache = ClaudeCache(root: file.appendingPathComponent("claude"))
        #expect {
            try ClaudeBundle.write(
                original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
                primary: ClaudeBundleTests.primary("x"), cache: cache, recognizer: ColourWords())
        } throws: { error in
            guard case ClaudeBundleError.cacheUnwritable(let folder, _) = error else {
                return false
            }
            return folder == cache.root
                && (error as? ClaudeBundleError)?.errorDescription?.contains(cache.root.path)
                    == true
                && !(error.localizedDescription.contains("couldn’t be completed"))
        }
    }

    @Test func aFailedRecognitionSaysSo() throws {
        struct Broken: TextRecognizer {
            struct Failure: Error {}
            func recognize(_ image: CGImage) throws -> [RecognizedText] { throw Failure() }
        }
        #expect {
            try ClaudeBundle.write(
                original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
                primary: ClaudeBundleTests.primary("x"), cache: Self.cache(), recognizer: Broken())
        } throws: { error in
            if case ClaudeBundleError.recognitionFailed = error { return true }
            return false
        }
    }

    @Test func expiredBundlesArePrunedOnWrite() throws {
        let cache = Self.cache()
        let old = cache.root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ClaudeCache.maximumAge)],
            ofItemAtPath: old.path)
        _ = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("new"), cache: cache, recognizer: ColourWords(),
            now: now)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: cache.root.path)
                == [ClaudeCache.folderName(for: ClaudeBundleTests.primary("new"))])
    }

    @Test func aBundleReportsWhatPruningCouldNotRemove() throws {
        let cache = Self.cache()
        let manager = FileManager.default
        let stuck = cache.root.appendingPathComponent("stuck")
        let locked = stuck.appendingPathComponent("locked")
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let now = Date()
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ClaudeCache.maximumAge)],
            ofItemAtPath: stuck.path)
        let bundle = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("x"), cache: cache, recognizer: ColourWords(),
            now: now)
        #expect(manager.fileExists(atPath: bundle.textFile.path))
        #expect(bundle.pruneFailures.map(\.url.lastPathComponent) == ["stuck"])
    }

    /// A cache folder that can't be listed is named as unreadable, not as unwritable.
    @Test func anUnlistableCacheSaysItCouldNotBeRead() throws {
        let cache = Self.cache()
        let manager = FileManager.default
        try cache.ensureRoot()
        try manager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: cache.root.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.root.path)
        }
        #expect {
            try ClaudeBundle.write(
                original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
                primary: ClaudeBundleTests.primary("x"), cache: cache, recognizer: ColourWords())
        } throws: { error in
            guard case ClaudeBundleError.cacheUnreadable(let folder, _) = error else {
                return false
            }
            return folder == cache.root
                && error.localizedDescription.hasPrefix("Couldn't read \(cache.root.path): ")
        }
    }

    /// A failure after staging exists removes the staging folder. The cache root loses write
    /// permission once the first bundle is in, so creating the staging folder is what fails.
    @Test func aFailedWriteLeavesNoStagingFolder() throws {
        let cache = Self.cache()
        let manager = FileManager.default
        _ = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
            primary: ClaudeBundleTests.primary("x"), cache: cache, recognizer: ColourWords())
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.root.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.root.path)
        }
        #expect(throws: ClaudeBundleError.self) {
            try ClaudeBundle.write(
                original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
                primary: ClaudeBundleTests.primary("x"), cache: cache, recognizer: ColourWords())
        }
        #expect(
            try manager.contentsOfDirectory(atPath: cache.root.path)
                == [ClaudeCache.folderName(for: ClaudeBundleTests.primary("x"))])
    }
}

/// The thumbnail's For Claude and `excerpt read` take a file the same way.
@Suite struct ClaudeBundleFileTests {
    /// A saved capture: `alpha` kept, `secret` cut out. Returns the primary.
    static func savedCapture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-file-\(UUID().uuidString)")
        let original = ColourWords.page(
            width: 200, height: 300, words: ["alpha": (20, 20), "secret": (20, 200)])
        let store = LibraryStore(folder: folder)
        let primary = try store.saveCapture(original, scale: 1, at: Date())
        try store.saveEdits(
            primary: primary, original: original,
            edits: EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 180, upper: 240)], salt: 7))
        return primary
    }

    @Test func aSavedPrimaryExportsWithItsCutMarked() throws {
        let primary = try Self.savedCapture()
        let bundle = try ClaudeBundle.write(
            contentsOf: primary, cache: ClaudeBundleTests.cache(), recognizer: ColourWords())
        #expect(bundle.text == "alpha\n[⋯ 60 px hidden]\n")
        #expect(
            bundle.folder.lastPathComponent
                == ClaudeCache.folderName(for: primary))
    }

    /// Review focus (privacy): a primary redacted after saving exports as itself; the master's
    /// original, which still holds what the redaction covers, never reaches Claude.
    @Test func aPrimaryAlteredAfterSavingExportsFlat() throws {
        let primary = try Self.savedCapture()
        var pixels = PixelBuffer(try PNGCodec.decode(Data(contentsOf: primary)).image)
        for y in 15..<35 {
            for x in 15..<85 {
                let i = (y * pixels.width + x) * 4
                pixels.bytes[i..<(i + 4)] = [0, 0, 0, 255]
            }
        }
        try PNGCodec.encode(pixels.makeImage(), scale: 1).write(to: primary)
        let bundle = try ClaudeBundle.write(
            contentsOf: primary, cache: ClaudeBundleTests.cache(), recognizer: ColourWords())
        #expect(!bundle.text.contains("alpha"))
        #expect(!bundle.text.contains("secret"))
        let tile = try PNGCodec.decode(Data(contentsOf: bundle.tiles[0])).image
        #expect(PixelBuffer(tile) == pixels)
    }

    /// Review focus (privacy): the editor opens that primary the same way, so its For Claude,
    /// which exports what the editor holds, sends the redacted pixels too.
    @Test func aPrimaryAlteredAfterSavingExportsFlatFromTheEditor() throws {
        let primary = try Self.savedCapture()
        var pixels = PixelBuffer(try PNGCodec.decode(Data(contentsOf: primary)).image)
        for y in 15..<35 {
            for x in 15..<85 {
                let i = (y * pixels.width + x) * 4
                pixels.bytes[i..<(i + 4)] = [0, 0, 0, 255]
            }
        }
        try PNGCodec.encode(pixels.makeImage(), scale: 1).write(to: primary)
        let capture = try LibraryStore(folder: primary.deletingLastPathComponent()).load(primary)
        let bundle = try ClaudeBundle.write(
            original: capture.original, edits: capture.edits,
            primary: ClaudeBundleTests.primary("x"),
            cache: ClaudeBundleTests.cache(), recognizer: ColourWords())
        #expect(!bundle.text.contains("alpha"))
        #expect(!bundle.text.contains("secret"))
        let tile = try PNGCodec.decode(Data(contentsOf: bundle.tiles[0])).image
        #expect(PixelBuffer(tile) == pixels)
    }
}
