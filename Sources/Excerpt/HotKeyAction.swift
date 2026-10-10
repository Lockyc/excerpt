import Carbon.HIToolbox
import ExcerptCapture
import ExcerptEditor

enum HotKeyAction: UInt32, CaseIterable {
    case area = 1
    case window = 2
    case fullscreen = 3
    case scrolling = 4
    case text = 5
    case selector = 6

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .scrolling: "Capture Scrolling Area"
        case .text: "Capture Text"
        case .selector: "Choose Capture Mode…"
        }
    }

    var defaultBinding: HotKeyBinding? {
        switch self {
        case .area:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKeyBinding.commandShift)
        case .window:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: HotKeyBinding.commandShift)
        case .text:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: HotKeyBinding.commandShift)
        case .selector:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: HotKeyBinding.commandShift)
        case .fullscreen, .scrolling: nil
        }
    }

    /// The modes the all-in-one selector offers: every action but the selector itself.
    static var modes: [HotKeyAction] { allCases.filter { $0 != .selector } }

    /// The mode's name in the selector: its title without `Capture `, so each starts with its own
    /// letter for the menu's type-select.
    var modeName: String { title.hasPrefix("Capture ") ? String(title.dropFirst(8)) : title }
}

extension HotKeyAction {
    /// The editor's own shortcuts by title (`For Claude in the editor`), which no action may
    /// take: a global hotkey gets the press before the editor sees it. Rebinding judges a
    /// candidate against these alongside the other actions' bindings.
    static let editorShortcuts: [String: HotKeyBinding] = Dictionary(
        EditorShortcut.allCases.compactMap { shortcut in
            HotKeyBinding(character: shortcut.key, flags: shortcut.modifiers).map {
                ("\(shortcut.name) in the editor", $0)
            }
        }, uniquingKeysWith: { first, _ in first })
}
