import AppKit
import Carbon.HIToolbox

struct HotKeyBinding: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32  // Carbon modifier mask

    static let commandShift = UInt32(cmdKey | shiftKey)  // 768

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
    ]

    /// The menu-item key equivalent for this binding's key, empty when the key has no name.
    var menuKey: String { Self.keyNames[keyCode] ?? "" }

    /// This binding's Carbon modifier mask as AppKit flags.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// e.g. `⌘⇧4`
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        return s + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }
}

enum HotKeyAction: UInt32, CaseIterable {
    case area = 1
    case window = 2
    case fullscreen = 3

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        }
    }

    var defaultBinding: HotKeyBinding? {
        switch self {
        case .area:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKeyBinding.commandShift)
        case .window:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: HotKeyBinding.commandShift)
        case .fullscreen: nil
        }
    }
}
