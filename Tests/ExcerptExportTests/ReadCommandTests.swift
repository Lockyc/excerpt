import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptExport

@Suite struct ReadCommandTests {
    @Test func argumentsChooseTheAppOrACommand() {
        #expect(ReadCommand.parse([]) == .app)
        #expect(ReadCommand.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == .app)
        #expect(ReadCommand.parse(["-psn_0_12345"]) == .app)
        #expect(ReadCommand.parse(["read", "shot.png"]) == .read("shot.png"))
        #expect(ReadCommand.parse(["read", "-"]) == .read("-"))
        #expect(ReadCommand.parse(["help"]) == .help)
        #expect(ReadCommand.parse(["--help"]) == .help)
        #expect(ReadCommand.parse(["read", "--help"]) == .help)
        #expect(ReadCommand.parse(["read"]) == .usage("read takes one image"))
        #expect(ReadCommand.parse(["read", "a.png", "b.png"]) == .usage("read takes one image"))
        #expect(ReadCommand.parse(["read", ""]) == .usage("read takes one image"))
        #expect(ReadCommand.parse(["snap"]) == .usage("unknown command 'snap'"))
    }

    static func scratch() throws -> (folder: URL, cache: ClaudeCache) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, ClaudeCache(root: folder.appendingPathComponent("cache")))
    }

    @Test func readPrintsTheTextAndTheTilePaths() throws {
        let (folder, cache) = try Self.scratch()
        let image = ColourWords.page(width: 200, height: 3_400, words: ["alpha": (20, 40)])
        try PNGCodec.encode(image, scale: 2).write(to: folder.appendingPathComponent("tall.png"))
        let output = ReadCommand.run(
            path: "tall.png", directory: folder, cache: cache, recognizer: ColourWords())
        #expect(output.status == 0)
        #expect(output.stdout == "alpha\n")
        let tiles = cache.root.appendingPathComponent("tall")
        #expect(
            output.stderr == "\(tiles.path)/tile-1-of-2.png\n\(tiles.path)/tile-2-of-2.png\n")
    }

    /// Review focus: an image with no text exits cleanly and says so.
    @Test func anImageWithNoTextSaysSo() throws {
        let (folder, cache) = try Self.scratch()
        try PNGCodec.encode(Fixtures.sheet(width: 100, height: 100), scale: 1)
            .write(to: folder.appendingPathComponent("blank.png"))
        let output = ReadCommand.run(
            path: "blank.png", directory: folder, cache: cache, recognizer: ColourWords())
        #expect(output.status == 0)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.hasSuffix("excerpt: no text found\n"))
    }

    /// Review focus: bad input exits non-zero with a message, never a trap.
    @Test func badInputExitsWithAMessageAndAStatus() throws {
        let (folder, cache) = try Self.scratch()
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let notImage = ReadCommand.run(
            path: "notes.txt", directory: folder, cache: cache, recognizer: ColourWords())
        #expect(notImage.status == ReadCommand.Status.dataError)
        #expect(notImage.stderr.hasPrefix("excerpt: "))
        #expect(notImage.stderr.contains("notes.txt isn't an image"))
        #expect(notImage.stdout.isEmpty)
        let missing = ReadCommand.run(
            path: "gone.png", directory: folder, cache: cache, recognizer: ColourWords())
        #expect(missing.status == ReadCommand.Status.noInput)
        try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1)
            .write(to: folder.appendingPathComponent("ok.png"))
        let cacheBlocked = ReadCommand.run(
            path: "ok.png", directory: folder,
            cache: ClaudeCache(root: folder.appendingPathComponent("ok.png/claude")),
            recognizer: ColourWords())
        #expect(cacheBlocked.status == ReadCommand.Status.cantCreate)
        #expect(cacheBlocked.stderr.contains("ok.png/claude"))
    }

    @Test func anAbsolutePathIgnoresTheDirectory() throws {
        let (folder, cache) = try Self.scratch()
        let file = folder.appendingPathComponent("abs.png")
        try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1).write(to: file)
        let output = ReadCommand.run(
            path: file.path, directory: URL(fileURLWithPath: "/"), cache: cache,
            recognizer: ColourWords())
        #expect(output.status == 0)
    }

    @Test func everyErrorMapsToItsStatus() {
        #expect(ReadCommand.status(for: ImageInputError.missing("a")) == 66)
        #expect(ReadCommand.status(for: ImageInputError.folder("a")) == 66)
        #expect(ReadCommand.status(for: ImageInputError.unreadable("a", "r")) == 66)
        #expect(ReadCommand.status(for: ImageInputError.notAnImage("a")) == 65)
        #expect(ReadCommand.status(for: ImageInputError.fileTooLarge("a", bytes: 1)) == 65)
        #expect(
            ReadCommand.status(for: ImageInputError.tooManyPixels("a", width: 1, height: 1)) == 65)
        #expect(
            ReadCommand.status(for: ImageInputError.rendersTooLarge("a", width: 1, height: 1)) == 65
        )
        #expect(ReadCommand.status(for: ImageInputError.damagedEdits("a", "r")) == 65)
        struct Reason: Error {}
        #expect(
            ReadCommand.status(
                for: ClaudeBundleError.cacheUnwritable(URL(fileURLWithPath: "/"), Reason())) == 73)
        #expect(ReadCommand.status(for: ClaudeBundleError.recognitionFailed(Reason())) == 70)
        #expect(ReadCommand.status(for: ClaudeBundleError.tileEncodingFailed(Reason())) == 70)
    }

    @Test func pruneFailuresAreNotedOnStderr() {
        let failure = (
            url: URL(fileURLWithPath: "/cache/old"),
            error: ClaudeCacheError(path: "/cache/old", reason: "permission denied")
        )
        #expect(
            ReadCommand.pruneNotes([failure])
                == "excerpt: couldn't remove old bundle /cache/old: permission denied\n")
        #expect(ReadCommand.pruneNotes([]).isEmpty)
    }

    @Test func dashesAndDashDash() {
        #expect(ReadCommand.parse(["read", "-x"]) == .read("-x"))
        #expect(ReadCommand.parse(["read", "--", "-x"]) == .read("-x"))
        #expect(ReadCommand.parse(["read", "--", "a.png"]) == .read("a.png"))
        #expect(ReadCommand.parse(["read", "--"]) == .usage("read takes one image"))
        #expect(ReadCommand.parse(["read", "--", "a", "b"]) == .usage("read takes one image"))
    }

    @Test func aClosedPipeDoesNotCrashTheWriter() throws {
        signal(SIGPIPE, SIG_IGN)
        let closed = Pipe()
        try closed.fileHandleForReading.close()
        let sink = Pipe()
        let output = ReadCommand.Output(stdout: "text\n", stderr: "", status: 0)
        #expect(
            ReadCommand.emit(
                output, stdout: closed.fileHandleForWriting,
                stderr: sink.fileHandleForWriting) == 0)
        let failed = ReadCommand.Output(stdout: "text\n", stderr: "", status: 65)
        let closed2 = Pipe()
        try closed2.fileHandleForReading.close()
        #expect(
            ReadCommand.emit(
                failed, stdout: closed2.fileHandleForWriting,
                stderr: sink.fileHandleForWriting) == 65)
    }

    @Test func anotherWriteErrorExitsWithIOError() throws {
        let sink = Pipe()
        let readOnly = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let output = ReadCommand.Output(stdout: "text\n", stderr: "", status: 0)
        #expect(
            ReadCommand.emit(output, stdout: readOnly, stderr: sink.fileHandleForWriting) == 74)
    }
}
