import AppKit
import ExcerptCore
import ExcerptEditor

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

    private lazy var thumbnails = ThumbnailStack(preferences: preferences) { [weak self] url in
        self?.openEditor(url)
    }
    /// Open editors by primary, so opening a capture again (or its master) brings its window
    /// forward.
    private var editors: [URL: EditorWindowController] = [:]
    private lazy var coordinator = CaptureCoordinator(preferences: preferences) {
        [weak self] url, image in
        self?.thumbnails.show(url: url, image: image)
    }

    func perform(_ action: HotKeyAction) {
        Task { @MainActor in await coordinator.run(action) }
    }

    /// Files opened with Excerpt from Finder's Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openEditor(url) }
    }

    func openEditor(_ url: URL) {
        let store = preferences.store
        let capture: LoadedCapture
        do {
            capture = try store.load(url)
        } catch {
            Alerts.openFailed(url, error)
            return
        }
        let primary = capture.primary.standardizedFileURL
        if let open = editors[primary] {
            open.show()
            return
        }
        let editor = EditorWindowController(
            capture: capture,
            save: { document in
                try store.saveEdits(
                    primary: capture.primary, original: capture.original, edits: document)
            },
            copy: { data in
                do {
                    try Pasteboard.copyPNG(data: data)
                } catch {
                    Alerts.clipboardFailed(capture.primary, error)
                }
            },
            onClose: { [weak self] in
                // The window is still mid-close; release it on the next turn, not under itself.
                DispatchQueue.main.async { self?.editors[primary] = nil }
            })
        editors[primary] = editor
        editor.show()
    }

    /// Each unsaved editor asks Save / Don't Save / Cancel; Cancel keeps the app running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for editor in editors.values where !editor.confirmClose() { return .terminateCancel }
        return .terminateNow
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
