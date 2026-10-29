import Carbon.HIToolbox
import ExcerptCapture
import ExcerptEditor

enum HotKeyAction: UInt32, CaseIterable {
    case area = 1
    case window = 2
    case fullscreen = 3
    case scrolling = 4
    case text = 5
    case record = 7
    case selector = 6

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .scrolling: "Capture Scrolling Area"
        case .text: "Capture Text"
        case .record: "Record Screen"
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
        case .record:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_7), modifiers: HotKeyBinding.commandShift)
        case .fullscreen, .scrolling: nil
        }
    }

    /// The modes the mode bar offers, in its order: those that use the selected area first.
    static let modes: [HotKeyAction] = [.area, .scrolling, .text, .record, .window, .fullscreen]

    /// The mode's name on the mode bar: its title without `Capture `, and Record for recording.
    var modeName: String {
        if self == .record { return "Record" }
        return title.hasPrefix("Capture ") ? String(title.dropFirst(8)) : title
    }

    /// The mode's SF Symbol on the mode bar.
    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .scrolling: "scroll"
        case .text: "text.viewfinder"
        case .window: "macwindow"
        case .fullscreen: "display"
        case .record: "record.circle"
        case .selector: "rectangle.3.group"
        }
    }

    /// Whether the mode runs on the area selected under the mode bar.
    var usesArea: Bool {
        switch self {
        case .area, .scrolling, .text, .record: true
        case .window, .fullscreen, .selector: false
        }
    }
}

extension HotKeyAction {
    /// The shortcuts no action may take, by title: the editor's own (`Save in the editor`),
    /// since a global hotkey gets the press before the editor sees it, and those every
    /// app answers. Rebinding judges a candidate against these alongside the other actions'
    /// bindings.
    static let reservedShortcuts: [String: HotKeyBinding] = Dictionary(
        EditorShortcut.allCases.compactMap { shortcut in
            HotKeyBinding(character: shortcut.key, flags: shortcut.modifiers).map {
                ("\(shortcut.name) in the editor", $0)
            }
        }, uniquingKeysWith: { first, _ in first }
    ).merging(HotKeyRules.appShortcuts) { editor, _ in editor }
}

extension HotKeyAction {
    /// Whether the action selects on the overlay: an area, a window, a scrolling region, an area
    /// to record, or an area under the mode bar.
    var selects: Bool {
        switch self {
        case .area, .window, .scrolling, .text, .record, .selector: true
        case .fullscreen: false
        }
    }
}
