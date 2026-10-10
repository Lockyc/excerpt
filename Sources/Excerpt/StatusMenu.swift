import AppKit

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let perform: (HotKeyAction) -> Void
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    private let hotKeyStatus: () -> [HotKeyAction: HotKeyCenter.Registration]

    init(
        perform: @escaping (HotKeyAction) -> Void, openLibrary: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hotKeyStatus: @escaping () -> [HotKeyAction: HotKeyCenter.Registration]
    ) {
        self.perform = perform
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.hotKeyStatus = hotKeyStatus
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "scissors", accessibilityDescription: "Excerpt")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuild(menu)
    }

    /// Hotkey notes reflect the state at the moment the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = hotKeyStatus()
        for action in HotKeyAction.allCases {
            let entry = NSMenuItem(
                title: action.title, action: #selector(capture(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(action.id)
            menu.addItem(entry)
            if let binding = action.defaultBinding {
                // Shown, not bound: the hotkey itself is global (HotKeyCenter).
                entry.keyEquivalent = binding.menuKey
                entry.keyEquivalentModifierMask = binding.modifierFlags
                if let state = status[action], state != .registered {
                    let title: String
                    switch state {
                    case .inUse: title = "\(binding.display) is in use by another app"
                    case .system:
                        title =
                            "\(binding.display) is a macOS shortcut: turn it off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots"
                    default: title = "\(binding.display) could not be registered"
                    }
                    let note = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    note.indentationLevel = 1
                    menu.addItem(note)
                }
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
