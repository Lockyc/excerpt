import Carbon.HIToolbox
import ExcerptCapture
import ExcerptEditor

enum HotKeyAction: UInt32, CaseIterable {
    case area = 1
    case window = 2
    case fullscreen = 3
    case scrolling = 4

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .scrolling: "Capture Scrolling Area"
        }
    }

    var defaultBinding: HotKeyBinding? {
        switch self {
        case .area:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKeyBinding.commandShift)
        case .window:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: HotKeyBinding.commandShift)
        case .fullscreen, .scrolling: nil
        }
    }
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
