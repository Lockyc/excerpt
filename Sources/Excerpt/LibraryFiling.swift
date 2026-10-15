import AppKit
import ExcerptCore

/// Runs `LibraryFiler` over the library at launch, daily, and whenever filing is switched on or
/// the library moves, off the main thread. Files it couldn't move, or a library it couldn't
/// read, are named in an alert once per launch for the same set.
@MainActor
final class LibraryFiling {
    private let preferences: Preferences
    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    /// What the last settings change saw, so only a switch-on or a new folder files.
    private var watched: (enabled: Bool, folder: URL)
    private var reported: Set<[String]> = []
    private var running = false

    init(preferences: Preferences) {
        self.preferences = preferences
        watched = (preferences.fileOldCaptures, preferences.libraryFolder)
    }

    func start() {
        run()
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        timer.tolerance = 60 * 60
        self.timer = timer
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        let now = (enabled: preferences.fileOldCaptures, folder: preferences.libraryFolder)
        defer { watched = now }
        if now.enabled && (!watched.enabled || now.folder != watched.folder) { run() }
    }

    private func run() {
        guard preferences.fileOldCaptures, !running else { return }
        running = true
        let filer = LibraryFiler(folder: preferences.libraryFolder)
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try filer.file(now: Date()) }
            }.value
            running = false
            switch result {
            case .success(let filed):
                report(filed.failed.map(\.description)) { Alerts.libraryNotFiled(filed.failed) }
            case .failure(let error):
                report([filer.folder.path]) { Alerts.libraryUnfileable(filer.folder, error) }
            }
        }
    }

    private func report(_ key: [String], _ alert: () -> Void) {
        guard !key.isEmpty, reported.insert(key.sorted()).inserted else { return }
        alert()
    }
}
