import AppKit
import ExcerptCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let hotKeys = HotKeyCenter()
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for action in HotKeyAction.allCases {
            guard let binding = action.defaultBinding else { continue }
            hotKeys.register(binding, id: action.id) { [weak self] in self?.perform(action) }
        }
        statusMenu = StatusMenu(
            perform: { [weak self] in self?.perform($0) },
            openLibrary: { [weak self] in self?.openLibrary() },
            openSettings: { [weak self] in self?.openSettings() },
            hotKeyStatus: { [weak self] in self?.hotKeyStatus() ?? [:] })
    }

    /// The one source of hotkey state; read when the menu opens and when Settings is shown.
    func hotKeyStatus() -> [HotKeyAction: HotKeyCenter.Registration] {
        var status: [HotKeyAction: HotKeyCenter.Registration] = [:]
        for action in HotKeyAction.allCases where action.defaultBinding != nil {
            status[action] = hotKeys.status(id: action.id)
        }
        return status
    }

    private lazy var thumbnails = ThumbnailStack(preferences: preferences)
    private lazy var coordinator = CaptureCoordinator(preferences: preferences) {
        [weak self] url, image in
        self?.thumbnails.show(url: url, image: image)
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

    private lazy var settings = SettingsWindowController(
        preferences: preferences, hotKeyStatus: { [weak self] in self?.hotKeyStatus() ?? [:] })

    func openSettings() { settings.show() }
}
