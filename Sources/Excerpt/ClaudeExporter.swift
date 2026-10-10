import AppKit
import ExcerptCore
import ExcerptExport

/// For Claude: builds the bundle off the main thread, then puts its `@` references on the
/// clipboard. A note says what is happening, because the first text recognition after login
/// can take many seconds while macOS prepares its model. One export per cache folder runs at a
/// time; the buttons that start one show it as busy until it ends.
///
/// The cache is pruned at launch, daily, and by every export. Expired entries that stay stuck,
/// or a cache folder that can't be read, are named in an alert, once per launch for the same
/// set, so a bundle that outlives its seven days is never kept quietly.
@MainActor
final class ClaudeExporter {
    private struct Job {
        let name: String
        var note: Toast.Token
    }

    /// The capture couldn't be loaded for a thumbnail's export: its alert is the open one.
    private struct OpenFailed: Error {
        let url: URL
        let error: Error
    }

    private let cache: ClaudeCache
    /// Exports running now, by cache folder: the folder is what two exports would fight over.
    private var running: [URL: Job] = [:]
    private var pruneTimer: Timer?
    /// The stuck entries already named this launch, each set as its sorted paths.
    private var reportedStuck: Set<[String]> = []
    private var reportedUnlistable = false
    /// Told a capture's name when its export starts and when it ends.
    var onBusyChange: ((String) -> Void)?

    init(cache: ClaudeCache = .standard) {
        self.cache = cache
    }

    /// The name an export of the capture at `primary` goes by: its file name without the
    /// extension.
    static func name(of primary: URL) -> String {
        primary.deletingPathExtension().lastPathComponent
    }

    /// Whether the capture called `name` is being prepared now.
    func isExporting(_ name: String) -> Bool { running[cache.folder(for: name)] != nil }

    /// The editor's export: what it shows, unsaved edits included.
    func export(original: CGImage, edits: EditDocument, name: String) {
        run(name: name) { (original, edits) }
    }

    /// A thumbnail's export: the primary at `url` as saved, loaded (with its master's edits)
    /// off the main thread while the note is already up.
    func export(primary url: URL, store: LibraryStore) {
        run(name: Self.name(of: url)) {
            do {
                let capture = try store.loadForRendering(url)
                return (capture.original, capture.edits)
            } catch {
                throw OpenFailed(url: url, error: error)
            }
        }
    }

    private func run(
        name: String, source: @escaping @Sendable () throws -> (CGImage, EditDocument)
    ) {
        let folder = cache.folder(for: name)
        guard running[folder] == nil else {
            NSSound.beep()
            return
        }
        running[folder] = Job(name: name, note: Self.showPreparing(name))
        onBusyChange?(name)
        let cache = cache
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let (original, edits) = try source()
                    return try ClaudeBundle.write(
                        original: original, edits: edits, name: name, cache: cache,
                        recognizer: VisionTextRecognizer())
                }
            }.value
            let note = running.removeValue(forKey: folder)?.note
            onBusyChange?(name)
            switch result {
            case .success(let bundle):
                do {
                    try Pasteboard.copyText(bundle.references)
                    resumePreparing(after: Toast.show(Self.summary(bundle)))
                } catch {
                    finish(note)
                    Alerts.claudeCopyFailed(bundle.folder, error)
                }
                reportStuck(bundle.pruneFailures)
            case .failure(let failure as OpenFailed):
                finish(note)
                Alerts.openFailed(failure.url, failure.error)
            case .failure(let error):
                finish(note)
                Alerts.claudeExportFailed(name, error)
            }
        }
    }

    private static func showPreparing(_ name: String) -> Toast.Token {
        Toast.show("Preparing \(name) for Claude…", seconds: nil)
    }

    /// Closes this export's note and puts back the note of one still running.
    private func finish(_ note: Toast.Token?) {
        if let note { Toast.dismiss(note) }
        resumePreparing(after: nil)
    }

    /// Once `summary` has had its time (or at once without one), shows the note of an export
    /// still running, unless another note has taken its place.
    private func resumePreparing(after summary: Toast.Token?) {
        Task {
            if summary != nil { try? await Task.sleep(for: .seconds(3)) }
            guard Toast.showsNothing(but: summary),
                let (folder, job) = running.first
            else { return }
            running[folder]?.note = Self.showPreparing(job.name)
        }
    }

    /// `Copied 8 tiles and text.md for Claude`, noting a capture with no text.
    static func summary(_ bundle: ClaudeBundle) -> String {
        let tiles = bundle.tiles.count == 1 ? "1 tile" : "\(bundle.tiles.count) tiles"
        return "Copied \(tiles) and text.md for Claude"
            + (bundle.text.isEmpty ? " · no text found" : "")
    }

    /// Prunes the cache now and once a day after, off the main thread.
    func startPruning() {
        prune()
        pruneTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        timer.tolerance = 60 * 60
        pruneTimer = timer
    }

    private func prune() {
        let cache = cache
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try cache.prune(now: Date()) }
            }.value
            switch result {
            case .success(let pruned):
                reportStuck(pruned.failed)
            case .failure(let error):
                guard !reportedUnlistable else { return }
                reportedUnlistable = true
                Alerts.claudeCacheUnlistable(cache.root, error)
            }
        }
    }

    /// Names the expired entries still in the cache, once per launch for the same set. An entry
    /// already gone (another prune got it first) isn't stuck.
    private func reportStuck(_ failures: [(url: URL, error: ClaudeCacheError)]) {
        let stuck = failures.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !stuck.isEmpty, reportedStuck.insert(stuck.map(\.url.path).sorted()).inserted
        else { return }
        Alerts.claudeCacheNotPruned(stuck.map(\.error))
    }
}

extension LibraryStore {
    /// A capture to render, as the editor and For Claude take it: `load`, then refused when its
    /// edits render it past the size limits, before anything is drawn.
    func loadForRendering(_ url: URL) throws -> LoadedCapture {
        let capture = try load(url)
        try ImageInput.checkRender(
            url.path, width: capture.original.width, height: capture.original.height,
            edits: capture.edits)
        return capture
    }
}
