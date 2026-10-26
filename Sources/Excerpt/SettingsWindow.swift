import AppKit
import Carbon.HIToolbox
import ExcerptCapture
import ExcerptCore
import SwiftUI

/// What Settings can do to the hotkeys, which the app delegate owns.
struct HotKeyControls {
    let states: () -> [HotKeyAction: HotKeyState]
    /// Sets an action's hotkey (nil clears it) and registers the result.
    let set: (HotKeyAction, HotKeyBinding?) -> Void
    /// Returns an action to its default hotkey and registers the result.
    let reset: (HotKeyAction) -> Void
    /// Unregisters every hotkey while one is recorded.
    let suspend: () -> Void
    /// Registers every hotkey again.
    let resume: () -> Void
}

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private let hotKeys: HotKeyModel
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    private var keyObserver: NSObjectProtocol?

    init(preferences: Preferences, hotKeys controls: HotKeyControls) {
        self.model = SettingsModel(preferences: preferences)
        self.hotKeys = HotKeyModel(controls: controls)
    }

    func show() {
        hotKeys.clearRefusals()
        hotKeys.refresh()
        if hosting == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(model: model, hotKeys: hotKeys))
            self.hosting = hosting
            let window = NSWindow(contentViewController: hosting)
            window.title = "Excerpt Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // The window doesn't take the form's size by itself; unsized, it's only a title bar.
            window.setContentSize(hosting.view.fittingSize)
            self.window = window
            // A macOS shortcut turned on or off elsewhere shows as soon as Settings is back.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hotKeys.refresh() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Nothing starts focused, so keys pressed as the window opens can't edit the prefix.
        window?.makeFirstResponder(nil)
    }
}

/// The Hotkeys section's state: each action's hotkey, the one being recorded, and why a
/// recorded combination was refused.
@MainActor
final class HotKeyModel: ObservableObject {
    private let controls: HotKeyControls
    @Published private(set) var states: [HotKeyAction: HotKeyState] = [:]
    @Published private(set) var recording: HotKeyAction?
    @Published private(set) var refusals: [HotKeyAction: String] = [:]
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(controls: HotKeyControls) {
        self.controls = controls
    }

    /// Reads every hotkey's state.
    func refresh() { states = controls.states() }

    /// Records the next key press as `action`'s hotkey. Every hotkey is unregistered meanwhile,
    /// so the press reaches here instead of starting a capture. Esc, Cancel, or any window
    /// losing focus stops recording and registers them again.
    func record(_ action: HotKeyAction) {
        stopRecording()
        controls.suspend()
        recording = action
        refusals[action] = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.recorded(event) }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    func stopRecording() {
        if endRecording() != nil { controls.resume() }
        refresh()
    }

    /// Stops listening for the press; the action that was being recorded, if any. Leaves the
    /// hotkeys unregistered for the caller to bring back.
    private func endRecording() -> HotKeyAction? {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        defer { recording = nil }
        return recording
    }

    /// A kept press registers every hotkey as it is saved; Esc or a refusal brings the old ones
    /// back.
    private func recorded(_ event: NSEvent) {
        guard let action = endRecording() else { return }
        let kept =
            Int(event.keyCode) != kVK_Escape
            && apply(HotKeyBinding(keyCode: event.keyCode, flags: event.modifierFlags), to: action)
        if !kept { controls.resume() }
        refresh()
    }

    func clear(_ action: HotKeyAction) {
        stopRecording()
        apply(nil, to: action)
    }

    func reset(_ action: HotKeyAction) {
        stopRecording()
        apply(action.defaultBinding, to: action)
    }

    /// Drops every refusal, which describes bindings as they stood when it was made.
    func clearRefusals() { refusals = [:] }

    /// Makes `candidate` `action`'s hotkey if the rules keep it, else leaves the binding and
    /// says why under the row. The default is stored as no override. True when kept.
    @discardableResult
    private func apply(_ candidate: HotKeyBinding?, to action: HotKeyAction) -> Bool {
        // A refused hotkey isn't registered, so it holds nothing.
        let bindings = Dictionary(
            states.filter { $0.value.refusal == nil }.map { ($0.key.title, $0.value.binding) },
            uniquingKeysWith: { first, _ in first })
        let verdict = HotKeyRules.judge(
            candidate, for: action.title, bindings: bindings,
            reserved: HotKeyAction.reservedShortcuts, system: HotKeyCenter.symbolicHotKeys())
        guard verdict.keeps else {
            refusals[action] = candidate.flatMap { verdict.message(for: $0) }
            return false
        }
        clearRefusals()
        if candidate == action.defaultBinding {
            controls.reset(action)
        } else {
            controls.set(action, candidate)
        }
        refresh()
        return true
    }

    /// Whether `action` has its default hotkey (or, with no default, none).
    func isDefault(_ action: HotKeyAction) -> Bool {
        states[action]?.binding == action.defaultBinding
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let preferences: Preferences
    @Published var folder: String {
        didSet { preferences.libraryFolder = URL(fileURLWithPath: folder) }
    }
    @Published var prefix: String { didSet { preferences.namePrefix = prefix } }
    @Published var fileOldCaptures: Bool {
        didSet { preferences.fileOldCaptures = fileOldCaptures }
    }
    @Published var playSound: Bool { didSet { preferences.playSound = playSound } }
    @Published var thumbnailAtPointer: Bool {
        didSet { preferences.thumbnailAtPointer = thumbnailAtPointer }
    }
    @Published var windowBackdrop: Bool { didSet { preferences.windowBackdrop = windowBackdrop } }
    @Published var padding: Double { didSet { preferences.windowPaddingPoints = padding } }
    @Published var backdropStyle: BackdropStyle {
        didSet { preferences.backdropStyle = backdropStyle }
    }
    @Published var recordingFormat: RecordingFormat {
        didSet { preferences.recordingFormat = recordingFormat }
    }
    @Published var backdrop: Color {
        didSet {
            guard let c = NSColor(backdrop).usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> UInt8 { UInt8((component * 255).rounded()) }
            preferences.backdropColor = RGBA(
                r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent), a: 255
            )
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        folder = preferences.libraryFolder.path
        prefix = preferences.namePrefix
        fileOldCaptures = preferences.fileOldCaptures
        playSound = preferences.playSound
        thumbnailAtPointer = preferences.thumbnailAtPointer
        windowBackdrop = preferences.windowBackdrop
        padding = preferences.windowPaddingPoints
        backdropStyle = preferences.backdropStyle
        recordingFormat = preferences.recordingFormat
        let c = preferences.backdropColor
        backdrop = Color(
            .sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// A library file name as the current prefix would produce it.
    var exampleFileName: String { LibraryNaming(prefix: prefix).baseName(for: Date()) + ".png" }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var hotKeys: HotKeyModel

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.folder).truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                TextField("File name prefix", text: $model.prefix)
                Text(model.exampleFileName)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "File captures older than \(Int(LibraryFiler.flatAge / (24 * 60 * 60))) days into month folders",
                    isOn: $model.fileOldCaptures)
            }
            Section("Capture") {
                Toggle("Play shutter sound", isOn: $model.playSound)
                Toggle("Show thumbnail at the pointer", isOn: $model.thumbnailAtPointer)
                Toggle("Place window captures on a backdrop", isOn: $model.windowBackdrop)
                LabeledContent("Backdrop padding") {
                    Stepper("\(Int(model.padding)) pt", value: $model.padding, in: 0...200, step: 8)
                }
                .disabled(!model.windowBackdrop)
                Picker("Backdrop", selection: $model.backdropStyle) {
                    Text("Desktop wallpaper").tag(BackdropStyle.wallpaper)
                    Text("Colour").tag(BackdropStyle.colour)
                }
                .disabled(!model.windowBackdrop)
                ColorPicker("Backdrop colour", selection: $model.backdrop, supportsOpacity: false)
                    .disabled(!model.windowBackdrop || model.backdropStyle == .wallpaper)
                if !model.windowBackdrop {
                    Text("Turn on the backdrop to set its padding and fill.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.backdropStyle == .wallpaper {
                    Text("The colour fills in when the wallpaper can't be captured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Recording") {
                Picker("Save recordings as", selection: $model.recordingFormat) {
                    Text("GIF").tag(RecordingFormat.gif)
                    Text("MP4").tag(RecordingFormat.mp4)
                }
                Text(
                    model.recordingFormat == .gif
                        ? "A recording too long for a \(GIFEncoder.byteBudgetText) GIF is saved as MP4."
                        : "MP4 keeps the recording's full resolution."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    hotKeyRow(action)
                }
            } header: {
                Text("Hotkeys")
            } footer: {
                Text(
                    "Record, then press the new shortcut; Esc cancels. A hotkey needs ⌘, ⌃ or ⌥ unless it's an F-key. Turn a macOS shortcut off before recording it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    @ViewBuilder private func hotKeyRow(_ action: HotKeyAction) -> some View {
        let state = hotKeys.states[action]
        let recording = hotKeys.recording == action
        LabeledContent(action.title) {
            HStack {
                Text(recording ? "Press a shortcut…" : state?.binding.display ?? "None")
                    .foregroundStyle(Self.color(state, recording: recording))
                Button(recording ? "Cancel" : "Record") {
                    recording ? hotKeys.stopRecording() : hotKeys.record(action)
                }
                Button("Clear") { hotKeys.clear(action) }
                    .disabled(state == nil)
                    .help(state == nil ? "No hotkey to clear" : "Remove this hotkey")
                Button("Default") { hotKeys.reset(action) }
                    .disabled(hotKeys.isDefault(action))
                    .help(
                        hotKeys.isDefault(action)
                            ? "Already the default"
                            : "Use \(action.defaultBinding?.display ?? "no hotkey")")
            }
        }
        ForEach([hotKeys.refusals[action], state?.note].compactMap { $0 }, id: \.self) { message in
            HStack {
                Text(message).foregroundStyle(.orange)
                if message == state?.note, state?.registration == .system {
                    Button("Open Keyboard Shortcuts…") { Self.openKeyboardShortcuts() }
                        .buttonStyle(.link)
                        .help("Turn the macOS shortcut off to give it to Excerpt")
                }
            }
            .font(.caption)
        }
    }

    private static func openKeyboardShortcuts() {
        NSWorkspace.shared.open(
            URL(
                string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
        )
    }

    private static func color(_ state: HotKeyState?, recording: Bool) -> Color {
        if recording { return .accentColor }
        guard let state else { return .secondary }
        return state.note == nil ? .primary : .orange
    }
}
