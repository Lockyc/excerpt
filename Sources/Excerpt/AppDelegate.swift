import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptEditor
import ExcerptExport
import ExcerptRecording

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
            hotKeyStates: { [weak self] in self?.hotKeyStates() ?? [:] },
            updater: Updater.make())
        statusMenu?.onStopRecording = { [weak self] in self?.coordinator.stopRecording() }
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
    private lazy var claude = ClaudeExporter(preferences: preferences)
    private lazy var filing = LibraryFiling(preferences: preferences)
    /// Open editors by primary, so opening a capture again (or its master) brings its window
    /// forward.
    private var editors: [URL: EditorWindowController] = [:]
    /// Open recording editors by master.
    private var recordingEditors: [URL: RecordingEditorWindowController] = [:]
    /// Masters being read for an editor, so opening one again meanwhile doesn't open a second.
    private var openingRecordings: Set<URL> = []
    /// Captures being loaded for an editor, by each path that names them (the file opened and
    /// the primary beside a master), so opening one again meanwhile doesn't open a second.
    private var openingCaptures: Set<URL> = []
    private lazy var coordinator = CaptureCoordinator(
        preferences: preferences,
        onDelivered: { [weak self] url, image in self?.thumbnails.show(url: url, image: image) },
        onRecorded: { [weak self] url, poster, note in
            self?.thumbnails.show(url: url, image: poster, isRecording: true, note: note)
        },
        onRecordingTime: { [weak self] in self?.statusMenu?.showRecording($0) })

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
    /// capture already open (or its master) brings its own window forward and is left out, and
    /// so is one still loading for an editor. A recording (its primary or master) opens in a
    /// recording editor of its own. The captures are read, decoded and checked against their
    /// masters off the main thread, in turn, so a tall one never stalls the app; a note names
    /// what is opening once that takes long enough to notice.
    func openEditors(_ urls: [URL]) {
        let store = preferences.store
        var loading: [URL] = []
        var names: Set<URL> = []
        for url in urls {
            if let paths = store.recordingPaths(for: url) {
                openRecordingEditor(paths, opened: url)
                continue
            }
            // An open capture focuses its window without decoding.
            let directory = url.deletingLastPathComponent()
            let sibling = LibraryNaming.primaryName(forOriginal: url.lastPathComponent)
                .map { directory.appendingPathComponent($0) }
            let paths = [url, sibling].compactMap { $0?.standardizedFileURL }
            if let open = paths.lazy.compactMap({ self.editors[$0] }).first {
                open.show()
                continue
            }
            guard openingCaptures.isDisjoint(with: paths), names.isDisjoint(with: paths) else {
                continue
            }
            names.formUnion(paths)
            loading.append(url)
        }
        guard !loading.isEmpty else { return }
        openingCaptures.formUnion(names)
        let what =
            loading.count == 1
            ? loading[0].deletingPathExtension().lastPathComponent : "\(loading.count) captures"
        let note = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(400))
            return Toast.show("Opening \(what)…", seconds: nil)
        }
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                loading.map { url in (url, Result { try store.loadForRendering(url) }) }
            }.value
            note.cancel()
            if let token = try? await note.value { Toast.dismiss(token) }
            guard let self else { return }
            openingCaptures.subtract(names)
            openLoaded(loaded)
        }
    }

    /// Opens the loaded captures in one editor, as `openEditors` describes; each that failed to
    /// load says why.
    private func openLoaded(_ loaded: [(url: URL, result: Result<LoadedCapture, any Error>)]) {
        let store = preferences.store
        var captures: [URL: LoadedCapture] = [:]
        var items: [(url: URL, created: Date)] = []
        for (url, result) in loaded {
            switch result {
            case .success(let capture):
                let primary = capture.primary.standardizedFileURL
                captures[primary] = capture
                let created =
                    (try? primary.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                items.append((primary, created))
            case .failure(let error):
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
            marginColor: preferences.backdropColor,
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

    /// Opens the recording at `paths` in its editor, or brings its open editor forward. Its
    /// Save always renders through `RecordingSave`, the path the save after stopping takes, so
    /// what it copies is the render of the edits the editor shows, and says when the GIF fell
    /// back to MP4.
    private func openRecordingEditor(_ paths: RecordingPaths, opened url: URL) {
        let key = paths.master.standardizedFileURL
        if let open = recordingEditors[key] {
            open.show()
            return
        }
        guard openingRecordings.insert(key).inserted else { return }
        let defaultFormat = preferences.recordingFormat
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { openingRecordings.remove(key) }
            let master: RecordingMaster
            do {
                master = try await RecordingMaster.read(paths.master)
            } catch {
                Alerts.openFailed(url, error)
                return
            }
            let existing = [RecordingFormat.gif, .mp4].map(paths.primary).first {
                FileManager.default.fileExists(atPath: $0.path)
            }
            let editor = RecordingEditorWindowController(
                master: master,
                primary: existing ?? paths.primary(master.edits?.format ?? defaultFormat),
                defaultFormat: defaultFormat,
                save: { edits in
                    guard
                        let (result, copied) = await RecordingSave.run(
                            master, edits: edits, paths: paths)
                    else { return false }
                    if let note = RecordingNote.text(
                        fellBackToMP4: result.fellBackToMP4, stoppedEarly: nil, eventsSaved: true)
                    {
                        Toast.show(
                            [copied ? "Recording saved and copied" : "Recording saved", note]
                                .joined(separator: " · "))
                    }
                    return copied
                },
                onClose: { [weak self] in
                    // The window is still mid-close; release it on the next turn, not under itself.
                    DispatchQueue.main.async { self?.recordingEditors[key] = nil }
                })
            recordingEditors[key] = editor
            editor.show()
        }
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
    /// Cancel keeps the app running. A recording editor's Save renders before it answers, so
    /// with one unsaved the quit waits on them, asked in turn. Then a recording in progress is
    /// stopped and kept, and the quit waits for every recording's save.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var asked = Set<ObjectIdentifier>()
        for editor in editors.values where asked.insert(ObjectIdentifier(editor)).inserted {
            if !editor.confirmClose() { return .terminateCancel }
        }
        let unsaved = recordingEditors.values.filter(\.hasUnsavedChanges)
        guard !unsaved.isEmpty || coordinator.isRecordingOrSaving else { return .terminateNow }
        confirmQuit(unsaved[...])
        return .terminateLater
    }

    /// Asks each recording editor in turn, answering the pending quit once all may close and
    /// the recordings are saved, or at the first that may not.
    private func confirmQuit(_ unsaved: ArraySlice<RecordingEditorWindowController>) {
        guard let editor = unsaved.first else {
            Task { @MainActor in
                await coordinator.finishRecordings()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return
        }
        editor.confirmClose { [weak self] closes in
            guard closes else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self?.confirmQuit(unsaved.dropFirst())
        }
    }

    /// Open Capture…: a panel at the library folder; the PNGs chosen open in the editor, several
    /// as a series, and each recording chosen in its recording editor.
    func chooseCapture() {
        let panel = NSOpenPanel()
        panel.directoryURL = preferences.libraryFolder
        panel.allowedContentTypes = [.png, .gif, .mpeg4Movie]
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
