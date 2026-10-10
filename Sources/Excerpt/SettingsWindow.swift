import AppKit
import ExcerptCore
import SwiftUI

final class SettingsWindowController {
    private let preferences: Preferences
    private let hotKeyStatus: [HotKeyAction: HotKeyCenter.Registration]
    private var window: NSWindow?

    init(preferences: Preferences, hotKeyStatus: [HotKeyAction: HotKeyCenter.Registration]) {
        self.preferences = preferences
        self.hotKeyStatus = hotKeyStatus
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                model: SettingsModel(preferences: preferences), hotKeyStatus: hotKeyStatus)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Excerpt Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsModel: ObservableObject {
    private let preferences: Preferences
    @Published var folder: String {
        didSet { preferences.libraryFolder = URL(fileURLWithPath: folder) }
    }
    @Published var prefix: String { didSet { preferences.namePrefix = prefix } }
    @Published var playSound: Bool { didSet { preferences.playSound = playSound } }
    @Published var windowBackdrop: Bool { didSet { preferences.windowBackdrop = windowBackdrop } }
    @Published var padding: Double { didSet { preferences.windowPaddingPoints = padding } }
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
        playSound = preferences.playSound
        windowBackdrop = preferences.windowBackdrop
        padding = preferences.windowPaddingPoints
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
    let hotKeyStatus: [HotKeyAction: HotKeyCenter.Registration]

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
            }
            Section("Capture") {
                Toggle("Play shutter sound", isOn: $model.playSound)
                Toggle("Place window captures on a backdrop", isOn: $model.windowBackdrop)
                LabeledContent("Backdrop padding") {
                    Stepper("\(Int(model.padding)) pt", value: $model.padding, in: 0...200, step: 8)
                }
                .disabled(!model.windowBackdrop)
                ColorPicker("Backdrop colour", selection: $model.backdrop, supportsOpacity: false)
                    .disabled(!model.windowBackdrop)
                if !model.windowBackdrop {
                    Text("Turn on the backdrop to set its padding and colour.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Hotkeys") {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        Text(hotKeyText(action)).foregroundStyle(hotKeyColor(action))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func hotKeyText(_ action: HotKeyAction) -> String {
        guard let binding = action.defaultBinding else { return "None" }
        switch hotKeyStatus[action] {
        case .registered, nil: return binding.display
        case .inUse: return "\(binding.display) — in use by another app"
        case .system: return "\(binding.display) — held by a macOS shortcut"
        case .failed(let status): return "\(binding.display) — failed (\(status))"
        }
    }

    private func hotKeyColor(_ action: HotKeyAction) -> Color {
        if case .registered = hotKeyStatus[action] { return .primary }
        return action.defaultBinding == nil ? .secondary : .orange
    }
}
