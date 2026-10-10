import AppKit

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let perform: (HotKeyAction) -> Void
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    private let hotKeyStates: () -> [HotKeyAction: HotKeyState]

    init(
        perform: @escaping (HotKeyAction) -> Void, openLibrary: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hotKeyStates: @escaping () -> [HotKeyAction: HotKeyState]
    ) {
        self.perform = perform
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.hotKeyStates = hotKeyStates
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "scissors", accessibilityDescription: "Excerpt")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuild(menu)
    }

    /// Hotkeys and their notes reflect the state at the moment the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let states = hotKeyStates()
        for action in HotKeyAction.allCases {
            let entry = NSMenuItem(
                title: action.title, action: #selector(capture(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(action.id)
            menu.addItem(entry)
            guard let state = states[action] else { continue }
            state.binding.show(on: entry)
            if let text = state.note {
                let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.indentationLevel = 1
                menu.addItem(note)
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Open Library Folder", action: #selector(library), keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Excerpt", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
    }

    @objc private func capture(_ sender: NSMenuItem) {
        if let action = HotKeyAction(rawValue: UInt32(sender.tag)) { perform(action) }
    }
    @objc private func library() { openLibrary() }
    @objc private func settings() { openSettings() }
}
