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

    func perform(_ action: HotKeyAction) {
        NSLog("capture: \(action)")  // replaced in Task 13
    }

    func openLibrary() {
        try? FileManager.default.createDirectory(
            at: preferences.libraryFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(preferences.libraryFolder)
    }

    func openSettings() {}  // Task 15
}
