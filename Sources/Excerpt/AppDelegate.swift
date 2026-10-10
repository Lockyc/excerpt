import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptEditor
import ExcerptExport

/// An action's hotkey and how its registration stands.
struct HotKeyState: Equatable {
    let binding: HotKeyBinding
    let registration: HotKeyCenter.Registration

    /// Why the hotkey may not fire, as the menu and Settings show it; nil when it will.
    var note: String? {
        switch registration {
        case .registered: nil
        case .inUse: "\(binding.display) is in use by another app"
        case .system: HotKeyVerdict.heldBySystem.message(for: binding)
        case .failed(let status): "\(binding.display) could not be registered (\(status))"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let hotKeys = HotKeyCenter()
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyHotKeys()
        statusMenu = StatusMenu(
            perform: { [weak self] in self?.perform($0) },
            openLibrary: { [weak self] in self?.openLibrary() },
            openSettings: { [weak self] in self?.openSettings() },
            hotKeyStates: { [weak self] in self?.hotKeyStates() ?? [:] })
        claude.onBusyChange = { [weak self] name in self?.showPreparingForClaude(name) }
        claude.startPruning()
    }

    /// Registers every action's current binding in place of whatever was registered.
    func applyHotKeys() {
        for action in HotKeyAction.allCases {
            hotKeys.unregister(id: action.id)
            guard let binding = preferences.binding(for: action) else { continue }
            hotKeys.register(binding, id: action.id) { [weak self] in self?.perform(action) }
        }
    }

    /// Unregisters every hotkey, so a press reaches Settings' recorder instead of starting a
    /// capture; `applyHotKeys` brings them back.
    func suspendHotKeys() {
        for action in HotKeyAction.allCases { hotKeys.unregister(id: action.id) }
    }

    /// The one source of hotkey state, for every action that has a hotkey; read when the menu
    /// opens and whenever Settings shows the hotkeys.
    func hotKeyStates() -> [HotKeyAction: HotKeyState] {
        var states: [HotKeyAction: HotKeyState] = [:]
        for action in HotKeyAction.allCases {
            guard let binding = preferences.binding(for: action) else { continue }
            states[action] = HotKeyState(
                binding: binding, registration: hotKeys.status(id: action.id))
        }
        return states
    }

    private lazy var thumbnails = ThumbnailStack(
        preferences: preferences, onEdit: { [weak self] url in self?.openEditor(url) },
        onClaude: { [weak self] url in self?.forClaude(url) })
    private let claude = ClaudeExporter()
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
        // Re-opening an open capture (or its master) focuses its window without decoding.
        let directory = url.deletingLastPathComponent()
        let sibling = LibraryNaming.primaryName(forOriginal: url.lastPathComponent)
            .map { directory.appendingPathComponent($0) }
        for key in [url, sibling].compactMap({ $0 }) {
            if let open = editors[key.standardizedFileURL] {
                open.show()
                return
            }
        }
        let store = preferences.store
        let capture: LoadedCapture
        do {
            capture = try store.loadForRendering(url)
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
            copy: { makePNG in
                do {
                    try Pasteboard.copyPNG(data: makePNG())
                } catch {
                    Alerts.copyFailed(capture.primary, error)
                }
            },
            forClaude: { [weak self] original, document in
                self?.claude.export(
                    original: original, edits: document,
                    name: ClaudeExporter.name(of: capture.primary))
            },
            onClose: { [weak self] in
                // The window is still mid-close; release it on the next turn, not under itself.
                DispatchQueue.main.async { self?.editors[primary] = nil }
            })
        editors[primary] = editor
        editor.isPreparingForClaude = claude.isExporting(ClaudeExporter.name(of: primary))
        editor.show()
    }

    /// For Claude from a thumbnail: the primary as `excerpt read` takes it, with its master's
    /// edits while it is exactly the master's render, and as its own pixels once changed since.
    func forClaude(_ url: URL) {
        claude.export(primary: url)
    }

    /// Brings every For Claude button of the capture called `name` in line with its export.
    private func showPreparingForClaude(_ name: String) {
        let busy = claude.isExporting(name)
        thumbnails.setPreparingForClaude(busy, name: name)
        for (primary, editor) in editors where ClaudeExporter.name(of: primary) == name {
            editor.isPreparingForClaude = busy
        }
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
        preferences: preferences,
        hotKeys: HotKeyControls(
            states: { [weak self] in self?.hotKeyStates() ?? [:] },
            set: { [weak self] action, binding in
                self?.preferences.setBinding(binding, for: action)
                self?.applyHotKeys()
            },
            reset: { [weak self] action in
                self?.preferences.resetBinding(for: action)
                self?.applyHotKeys()
            },
            suspend: { [weak self] in self?.suspendHotKeys() },
            resume: { [weak self] in self?.applyHotKeys() }))

    func openSettings() { settings.show() }
}

extension LibraryStore {
    /// A capture to edit: `load`, so a primary opens its master, then refused when its edits
    /// render it past the size limits, before anything is drawn.
    func loadForRendering(_ url: URL) throws -> LoadedCapture {
        let capture = try load(url)
        try ImageInput.checkRender(
            url.path, width: capture.original.width, height: capture.original.height,
            edits: capture.edits)
        return capture
    }
}
