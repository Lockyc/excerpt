import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptEditor
import ExcerptExport

/// An action's hotkey and how its registration stands.
struct HotKeyState: Equatable {
    let binding: HotKeyBinding
    let registration: HotKeyCenter.Registration
    /// Why the stored hotkey was refused, so never registered; nil when it was kept.
    let refusal: HotKeyVerdict?

    /// Why the hotkey may not fire, as the menu and Settings show it; nil when it will.
    var note: String? {
        if let refusal { return refusal.message(for: binding) }
        return switch registration {
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
            recentCaptures: { [weak self] in
                try self?.preferences.store.recentCaptures(limit: StatusMenu.recentLimit) ?? []
            },
            openCapture: { [weak self] in self?.openEditor($0) },
            chooseCapture: { [weak self] in self?.chooseCapture() },
            openLibrary: { [weak self] in self?.openLibrary() },
            openSettings: { [weak self] in self?.openSettings() },
            hotKeyStates: { [weak self] in self?.hotKeyStates() ?? [:] })
        claude.onBusyChange = { [weak self] primary in self?.showPreparingForClaude(primary) }
        claude.startPruning()
        filing.start()
    }

    /// Registers every action's current binding that the rules keep, in place of whatever was
    /// registered.
    func applyHotKeys() {
        hotKeys.resume()
        for action in HotKeyAction.allCases { hotKeys.unregister(id: action.id) }
        for (action, binding, verdict) in judgedHotKeys() where verdict.keeps {
            hotKeys.register(binding, id: action.id) { [weak self] in self?.perform(action) }
        }
    }

    /// Every action's stored hotkey with the verdict it is registered under, in action order.
    private func judgedHotKeys() -> [(HotKeyAction, HotKeyBinding, HotKeyVerdict)] {
        let stored = HotKeyAction.allCases.compactMap { action in
            preferences.binding(for: action).map { (action, $0) }
        }
        let verdicts = HotKeyRules.judgeStored(
            stored.map { ($0.0.title, $0.1) }, reserved: HotKeyAction.reservedShortcuts)
        return zip(stored, verdicts).map { ($0.0, $0.1, $1) }
    }

    /// Unregisters every hotkey, so a press reaches Settings' recorder instead of starting a
    /// capture, while their states read as before; `applyHotKeys` brings them back.
    func suspendHotKeys() { hotKeys.suspend() }

    /// The one source of hotkey state, for every action that has a hotkey; read when the menu
    /// opens and whenever Settings shows the hotkeys.
    func hotKeyStates() -> [HotKeyAction: HotKeyState] {
        var states: [HotKeyAction: HotKeyState] = [:]
        for (action, binding, verdict) in judgedHotKeys() {
            states[action] = HotKeyState(
                binding: binding, registration: hotKeys.status(id: action.id),
                refusal: verdict.keeps ? nil : verdict)
        }
        return states
    }

    private lazy var thumbnails = ThumbnailStack(
        preferences: preferences, onEdit: { [weak self] url in self?.openEditor(url) },
        onEditAll: { [weak self] urls in self?.openEditors(urls) },
        onClaude: { [weak self] url in self?.forClaude(url) })
    private let claude = ClaudeExporter()
    private lazy var filing = LibraryFiling(preferences: preferences)
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

    /// Files opened with Excerpt from Finder's Open With, or handed over by another app; several
    /// at once open as a series.
    func application(_ application: NSApplication, open urls: [URL]) {
        openEditors(urls)
    }

    func openEditor(_ url: URL) { openEditors([url]) }

    /// Opens the captures in one editor, a series when there are several, in creation order. A
    /// capture already open (or its master) brings its own window forward and is left out.
    func openEditors(_ urls: [URL]) {
        let store = preferences.store
        var captures: [URL: LoadedCapture] = [:]
        var items: [(url: URL, created: Date)] = []
        for url in urls {
            // An open capture focuses its window without decoding.
            let directory = url.deletingLastPathComponent()
            let sibling = LibraryNaming.primaryName(forOriginal: url.lastPathComponent)
                .map { directory.appendingPathComponent($0) }
            if let open = [url, sibling].compactMap({ $0 })
                .lazy.compactMap({ self.editors[$0.standardizedFileURL] }).first
            {
                open.show()
                continue
            }
            do {
                let capture = try store.loadForRendering(url)
                let primary = capture.primary.standardizedFileURL
                captures[primary] = capture
                let created =
                    (try? primary.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                items.append((primary, created))
            } catch {
                Alerts.openFailed(url, error)
            }
        }
        let arranged = SeriesOrder.arrange(items, open: Set(editors.keys))
        for primary in arranged.alreadyOpen { editors[primary]?.show() }
        let series = arranged.series.compactMap { captures[$0] }
        guard let first = series.first else { return }
        let editor = EditorWindowController(
            captures: series,
            save: { capture, document in
                try store.saveEdits(
                    primary: capture.primary, original: capture.original, edits: document,
                    replacingMaster: capture.supersedesMaster)
            },
            copy: { makePNGs in
                do {
                    try Pasteboard.copyPNGs(makePNGs())
                    return true
                } catch {
                    Alerts.copyFailed(first.primary, error)
                    return false
                }
            },
            forClaude: { [weak self] capture, original, document in
                self?.claude.export(
                    original: original, edits: document, primary: capture.primary)
            },
            borderStyle: preferences.editorBorder,
            rememberBorder: { [weak self] in self?.preferences.editorBorder = $0 },
            annotationStyle: preferences.editorStyle,
            rememberStyle: { [weak self] in self?.preferences.editorStyle = $0 },
            onClose: { [weak self] in
                // The window is still mid-close; release it on the next turn, not under itself.
                DispatchQueue.main.async {
                    for primary in arranged.series { self?.editors[primary] = nil }
                }
            })
        for primary in arranged.series { editors[primary] = editor }
        editor.isPreparingForClaude = arranged.series.contains { claude.isExporting($0) }
        editor.show()
    }

    /// For Claude from a thumbnail: the primary as `excerpt read` takes it, with its master's
    /// edits while it is exactly the master's render, and as its own pixels once changed since.
    func forClaude(_ url: URL) {
        claude.export(primary: url)
    }

    /// Brings every For Claude button of the capture at `capture` in line with its export.
    private func showPreparingForClaude(_ capture: URL) {
        let busy = claude.isExporting(capture)
        thumbnails.setPreparingForClaude(busy) { self.claude.isSameCapture($0, capture) }
        for (primary, editor) in editors where claude.isSameCapture(primary, capture) {
            editor.isPreparingForClaude = busy
        }
    }

    /// Each unsaved editor asks Save / Don't Save / Cancel, once however many captures it holds;
    /// Cancel keeps the app running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var asked = Set<ObjectIdentifier>()
        for editor in editors.values where asked.insert(ObjectIdentifier(editor)).inserted {
            if !editor.confirmClose() { return .terminateCancel }
        }
        return .terminateNow
    }

    /// Open Capture…: a panel at the library folder; the PNGs chosen open in the editor, several
    /// as a series.
    func chooseCapture() {
        let panel = NSOpenPanel()
        panel.directoryURL = preferences.libraryFolder
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.prompt = "Edit"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openEditors(panel.urls)
        }
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
    /// A capture to edit: `load`, so a primary opens its master while it is still the master's
    /// render, with every image it reads refused when it or the render of its edits is past the
    /// size limits, before any pixel is decoded or drawn.
    func loadForRendering(_ url: URL) throws -> LoadedCapture {
        try load(url) { file, width, height, edits in
            try ImageInput.checkEditable(file.path, width: width, height: height, edits: edits)
        }
    }
}
