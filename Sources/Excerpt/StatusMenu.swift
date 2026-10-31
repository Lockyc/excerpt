import AppKit
import ExcerptCore
import Sparkle

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updater: SPUStandardUpdaterController?
    private let perform: (HotKeyAction) -> Void
    private let chooseCapture: () -> Void
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    private let hotKeyStates: () -> [HotKeyAction: HotKeyState]

    init(
        perform: @escaping (HotKeyAction) -> Void,
        chooseCapture: @escaping () -> Void, openLibrary: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hotKeyStates: @escaping () -> [HotKeyAction: HotKeyState],
        updater: SPUStandardUpdaterController?
    ) {
        self.updater = updater
        self.perform = perform
        self.chooseCapture = chooseCapture
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.hotKeyStates = hotKeyStates
        super.init()
        item.button?.image = Self.icon
        menu.delegate = self
        item.menu = menu
        rebuild(menu)
    }

    private let menu = NSMenu()
    private static let icon = NSImage(
        systemSymbolName: "scissors", accessibilityDescription: "Excerpt")
    /// The icon's font and image position while the item shows a recording, to restore after.
    private var iconLook: (font: NSFont?, imagePosition: NSControl.ImagePosition)?
    /// Called when the item is clicked while it shows a recording.
    var onStopRecording: () -> Void = {}

    /// While `text` is set, the item is a stop button showing it, the recording's time, and a
    /// click stops the recording; nil brings back the icon and the menu.
    func showRecording(_ text: String?) {
        guard let button = item.button else { return }
        if let text {
            if iconLook == nil {
                iconLook = (button.font, button.imagePosition)
                item.menu = nil
                item.length = NSStatusItem.variableLength
                button.image = NSImage(
                    systemSymbolName: "stop.circle", accessibilityDescription: "Stop Recording")
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize, weight: .regular)
                button.target = self
                button.action = #selector(stopRecording)
                button.toolTip = "Stop recording"
            }
            button.title = text
        } else {
            guard let iconLook else { return }
            self.iconLook = nil
            button.title = ""
            button.image = Self.icon
            button.font = iconLook.font
            button.imagePosition = iconLook.imagePosition
            button.action = nil
            button.target = nil
            button.toolTip = nil
            item.length = NSStatusItem.squareLength
            item.menu = menu
        }
    }

    @objc private func stopRecording() { onStopRecording() }

    /// Hotkeys and their notes reflect the state at the moment the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let states = hotKeyStates()
        for action in HotKeyAction.allCases where action.isCapture {
            addAction(action, states: states, to: menu)
        }
        menu.addItem(.separator())
        addAction(.recent, states: states, to: menu)
        menu.addItem(withTitle: "Open Capture…", action: #selector(choose), keyEquivalent: "")
            .target = self
        menu.addItem(
            withTitle: "Open Library Folder", action: #selector(library), keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
            .target = self
        // Shown without an updater too (`swift run`), just inert, so the menu reads the same.
        menu.addItem(
            withTitle: "Check for Updates…",
            action: updater.map { _ in #selector(SPUStandardUpdaterController.checkForUpdates(_:))
            },
            keyEquivalent: ""
        ).target = updater
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Excerpt", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
    }

    /// An action's entry with its hotkey, and under it the note on that hotkey, if any.
    private func addAction(
        _ action: HotKeyAction, states: [HotKeyAction: HotKeyState], to menu: NSMenu
    ) {
        let entry = NSMenuItem(
            title: action.title, action: #selector(capture(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = Int(action.id)
        menu.addItem(entry)
        guard let state = states[action] else { return }
        state.binding.show(on: entry)
        if let text = state.note {
            let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.indentationLevel = 1
            menu.addItem(note)
        }
    }

    @objc private func choose() { chooseCapture() }
    @objc private func capture(_ sender: NSMenuItem) {
        if let action = HotKeyAction(rawValue: UInt32(sender.tag)) { perform(action) }
    }
    @objc private func library() { openLibrary() }
    @objc private func settings() { openSettings() }
}
