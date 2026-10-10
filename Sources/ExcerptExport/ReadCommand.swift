import Darwin
import Foundation

/// `excerpt read <image>`: the For Claude bundle for any image file, from the command line.
/// Runs headless in the app's own binary before any `NSApplication` starts, and needs no
/// Screen Recording permission because it captures nothing.
public enum ReadCommand {
    public enum Invocation: Equatable {
        /// No command: start the menu-bar app. Reached only from inside an app bundle, where launch
        /// arguments AppKit owns (`-NS…`, `-psn_…`) land here too.
        case app
        case read(String)
        case help
        case usage(String)
    }

    /// What a run prints and how it exits.
    public struct Output: Equatable {
        public var stdout = ""
        public var stderr = ""
        public var status: Int32 = 0
    }

    /// Exit statuses, from `sysexits.h`.
    public enum Status {
        public static let usage: Int32 = 64
        public static let dataError: Int32 = 65
        public static let noInput: Int32 = 66
        public static let software: Int32 = 70
        public static let cantCreate: Int32 = 73
        public static let ioError: Int32 = 74
    }

    public static let usage = """
        usage: excerpt read [--] <image>

        A name starting with '-' needs `--` before it or a leading `./`.

        Reads an image the way For Claude exports a capture: its text in reading order, with any
        excerpt cuts marked, on stdout, and the paths of 1× tiles Claude can read on stderr.

        """

    /// `arguments` without the program name; `path` is the program's path as invoked (`argv[0]`).
    /// Only a path inside an app bundle — launched from Finder, `open` or a login item — can start
    /// the menu-bar app. Every other invocation is the command line, under any spelling of the
    /// `PATH` link and from `swift run`, so a mistyped option prints usage instead of starting a
    /// second menu-bar instance in the terminal.
    public static func parse(_ arguments: [String], invokedAt path: String) -> Invocation {
        let commandLine = !path.contains(".app/Contents/MacOS/")
        guard let command = arguments.first else {
            return commandLine ? .usage("name a command") : .app
        }
        switch command {
        case "-h", "--help", "help": return .help
        case "read":
            var rest = Array(arguments.dropFirst())
            if rest == ["-h"] || rest == ["--help"] { return .help }
            if rest.first == "--" { rest.removeFirst() }
            guard rest.count == 1, let path = rest.first, !path.isEmpty else {
                return .usage("read takes one image")
            }
            return .read(path)
        default:
            if command.hasPrefix("-") {
                return commandLine ? .usage("unknown option '\(command)'") : .app
            }
            return .usage("unknown command '\(command)'")
        }
    }

    /// Builds the bundle for the image at `path` (relative to `directory`) in `cache`.
    public static func run(
        path: String, directory: URL, cache: ClaudeCache, recognizer: any TextRecognizer,
        now: Date = Date()
    ) -> Output {
        let url =
            (path.hasPrefix("/")
            ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
            .standardizedFileURL
        do {
            let bundle = try ClaudeBundle.write(
                contentsOf: url, cache: cache, recognizer: recognizer, now: now)
            var output = Output(stdout: bundle.text)
            output.stderr = pruneNotes(bundle.pruneFailures)
            output.stderr += bundle.tiles.map { $0.path + "\n" }.joined()
            if bundle.text.isEmpty { output.stderr += "excerpt: no text found\n" }
            return output
        } catch let error as ImageInputError {
            return failure(error, status(for: error))
        } catch let error as ClaudeBundleError {
            return failure(error, status(for: error))
        } catch let error as CaptureTextError {
            return Output(
                stderr: "excerpt: \(url.path): \(error.localizedDescription)\n",
                status: status(for: error))
        } catch {
            return failure(error, Status.software)
        }
    }

    /// Every case is listed, so a new one can't fall to a wrong code by default.
    static func status(for error: ImageInputError) -> Int32 {
        switch error {
        case .missing, .folder, .unreadable: Status.noInput
        case .notAnImage, .fileTooLarge, .tooManyPixels, .rendersTooLarge, .damagedEdits:
            Status.dataError
        }
    }

    /// A capture cut too finely to read is bad data, like damaged edits.
    static func status(for error: CaptureTextError) -> Int32 {
        switch error {
        case .tooManyRegions: Status.dataError
        }
    }

    /// A tile that won't encode is a fault in excerpt, not in the cache; a cache that can't be
    /// listed is an I/O error.
    static func status(for error: ClaudeBundleError) -> Int32 {
        switch error {
        case .cacheUnwritable: Status.cantCreate
        case .cacheUnreadable: Status.ioError
        case .recognitionFailed, .tileEncodingFailed: Status.software
        }
    }

    /// Old bundles that couldn't be removed: reported, never fatal.
    static func pruneNotes(_ failures: [(url: URL, error: ClaudeCacheError)]) -> String {
        failures.map {
            "excerpt: couldn't remove old bundle \($0.url.path): \($0.error.reason)\n"
        }.joined()
    }

    private static func failure(_ error: any Error, _ status: Int32) -> Output {
        Output(stderr: "excerpt: \(error.localizedDescription)\n", status: status)
    }

    /// Runs a command named in `arguments` (without the program name), printing its output;
    /// nil when there is none and the app should start. `path` is as for `parse`.
    public static func main(_ arguments: [String], invokedAt path: String) -> Int32? {
        let output: Output
        let invocation = parse(arguments, invokedAt: path)
        if invocation != .app { signal(SIGPIPE, SIG_DFL) }
        switch invocation {
        case .app: return nil
        case .help: output = Output(stdout: usage)
        case .usage(let problem):
            output = Output(stderr: "excerpt: \(problem)\n\n" + usage, status: Status.usage)
        case .read(let path):
            output = run(
                path: path,
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                cache: .standard, recognizer: VisionTextRecognizer())
        }
        return emit(output, stdout: .standardOutput, stderr: .standardError)
    }

    /// Writes `output`, returning its status. A reader that has gone away (EPIPE) ends quietly
    /// with the status unchanged; any other write failure is noted on stderr and exits 74.
    static func emit(_ output: Output, stdout: FileHandle, stderr: FileHandle) -> Int32 {
        var status = output.status
        for (handle, text) in [(stdout, output.stdout), (stderr, output.stderr)] {
            do {
                try handle.write(contentsOf: Data(text.utf8))
            } catch let error as NSError where error.isBrokenPipe {
                continue
            } catch {
                try? stderr.write(
                    contentsOf: Data(
                        "excerpt: couldn't write the output: \(error.localizedDescription)\n".utf8))
                status = Status.ioError
            }
        }
        return status
    }
}

extension NSError {
    fileprivate var isBrokenPipe: Bool {
        (domain == NSPOSIXErrorDomain && code == Int(EPIPE))
            || (underlying?.isBrokenPipe ?? false)
    }

    private var underlying: NSError? { userInfo[NSUnderlyingErrorKey] as? NSError }
}
