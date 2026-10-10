import AppKit
import ExcerptCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let hotKeys = HotKeyCenter()
    private var statusMenu: StatusMenu?
    private(set) var hotKeyStatus: [HotKeyAction: HotKeyCenter.Registration] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        for action in HotKeyAction.allCases {
            guard let binding = action.defaultBinding else { continue }
            hotKeyStatus[action] = hotKeys.register(binding, id: action.id) { [weak self] in
                self?.perform(action)
            }
        }
        statusMenu = StatusMenu(
            perform: { [weak self] in self?.perform($0) },
            openLibrary: { [weak self] in self?.openLibrary() },
            openSettings: { [weak self] in self?.openSettings() },
            hotKeyStatus: hotKeyStatus)
    }

    private lazy var coordinator = CaptureCoordinator(preferences: preferences) { url, _ in
        NSLog("captured \(url.lastPathComponent)")  // the thumbnail replaces this in Task 14
    }

    func perform(_ action: HotKeyAction) {
        Task { @MainActor in await coordinator.run(action) }
    }

    func openLibrary() {
        let folder = preferences.libraryFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Alerts.libraryUnwritable(folder, error)
            return
        }
        NSWorkspace.shared.open(folder)
    }

    func openSettings() {}  // Task 15
}
