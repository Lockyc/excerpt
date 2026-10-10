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

    /// The roadmap gate's shape: a 10,000-point capture at 2× becomes eight 1× tiles and the
    /// text, with the cut written in.
    @Test func aTallCaptureBecomesOneTimesTilesAndText() throws {
        let original = ColourWords.page(
            width: 100, height: 20_000, words: ["alpha": (20, 100), "omega": (20, 19_800)])
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 9_000, upper: 9_036)], salt: 7)
        let bundle = try ClaudeBundle.write(
            original: original, edits: edits, name: "Excerpt 2026-10-10 at 09.43.29",
            cache: Self.cache(), recognizer: ColourWords())
        // Uppercase and spaces make the name lossy, so the folder carries a hash suffix.
        let name = "Excerpt 2026-10-10 at 09.43.29"
        #expect(
            bundle.folder.lastPathComponent == ClaudeCache.folderName(for: name))
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
    }

    /// Review focus: a 1× capture and a 2× capture of the same content give the same tiles.
    @Test func aOneTimesSourceIsNotScaled() throws {
        let original = Fixtures.sheet(width: 500, height: 1_000)
        let bundle = try ClaudeBundle.write(
            original: original, edits: EditDocument(scale: 1), name: "one", cache: Self.cache(),
            recognizer: ColourWords())
        #expect(bundle.tiles.count == 1)
        let tile = try PNGCodec.decode(Data(contentsOf: bundle.tiles[0])).image
        #expect(PixelBuffer(tile) == PixelBuffer(original))
    }

    @Test func writingAgainReplacesTheFolder() throws {
        let cache = Self.cache()
        let tall = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 4_000), edits: EditDocument(scale: 1),
            name: "same", cache: cache, recognizer: ColourWords())
        #expect(tall.tiles.count == 3)
        let short = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 100, height: 400), edits: EditDocument(scale: 1),
            name: "same", cache: cache, recognizer: ColourWords())
        let left = try FileManager.default.contentsOfDirectory(atPath: short.folder.path).sorted()
        #expect(left == ["text.md", "tile-1-of-1.png"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: cache.root.path)
        #expect(siblings == ["same"])
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
                name: "x", cache: cache, recognizer: ColourWords())
        } throws: { error in
            guard case ClaudeBundleError.cacheUnwritable(let folder, _) = error else {
                return false
            }
            return folder == cache.root
                && (error as? ClaudeBundleError)?.errorDescription?.contains(cache.root.path)
                    == true
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
                name: "x", cache: Self.cache(), recognizer: Broken())
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
            name: "new", cache: cache, recognizer: ColourWords(), now: now)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.root.path) == ["new"])
    }

    @Test func aBundleReportsWhatPruningCouldNotRemove() throws {
        let bundle = try ClaudeBundle.write(
            original: Fixtures.sheet(width: 50, height: 50), edits: EditDocument(scale: 1),
            name: "x", cache: Self.cache(), recognizer: ColourWords())
        #expect(bundle.pruneFailures.isEmpty)
    }
}
