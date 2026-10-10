import AppKit
import ExcerptCore
import ExcerptExport

/// For Claude: builds the bundle off the main thread, then puts its `@` references on the
/// clipboard. A note says what is happening, because the first text recognition after login
/// can take many seconds while macOS prepares its model. One export per capture runs at a
/// time; the buttons that start one show it as busy until it ends.
///
/// The cache is pruned at launch and daily as well as by every export. A background prune that
/// can't remove an entry logs it; the next export prunes again and names every entry still
/// stuck in an alert, so a bundle that outlives its seven days is never kept quietly.
@MainActor
final class ClaudeExporter {
    private let cache: ClaudeCache
    private var running: Set<String> = []
    private var pruneTimer: Timer?
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
    func isExporting(_ name: String) -> Bool { running.contains(name) }

    func export(original: CGImage, edits: EditDocument, name: String) {
        guard running.insert(name).inserted else {
            NSSound.beep()
            return
        }
        onBusyChange?(name)
        let note = Toast.show("Preparing \(name) for Claude…", seconds: nil)
        let cache = cache
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ClaudeBundle.write(
                        original: original, edits: edits, name: name, cache: cache,
                        recognizer: VisionTextRecognizer())
                }
            }.value
            running.remove(name)
            onBusyChange?(name)
            switch result {
            case .success(let bundle):
                do {
                    try Pasteboard.copyText(bundle.references)
                    Toast.show(Self.summary(bundle))
                } catch {
                    Toast.dismiss(note)
                    Alerts.claudeCopyFailed(bundle.folder, error)
                }
                // An entry the background prune removed meanwhile is gone, not stuck.
                let stuck = bundle.pruneFailures.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                if !stuck.isEmpty { Alerts.claudeCacheNotPruned(stuck.map(\.error)) }
            case .failure(let error):
                Toast.dismiss(note)
                Alerts.claudeExportFailed(name, error)
            }
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
        Task.detached(priority: .utility) {
            do {
                for failure in try cache.prune(now: Date()).failed {
                    NSLog(
                        "excerpt: couldn't remove old Claude bundle %@", failure.error.description)
                }
            } catch {
                NSLog("excerpt: couldn't prune the Claude cache: %@", "\(error)")
            }
        }
    }
}
