import AppKit
import Carbon.HIToolbox

/// A global hotkey: a Carbon key code and Carbon modifier mask, as `RegisterEventHotKey` takes
/// them.
public struct HotKeyBinding: Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let commandShift = UInt32(cmdKey | shiftKey)  // 768

    /// The one table of modifiers a hotkey can carry, in menu order: Carbon bit, AppKit flag,
    /// symbol, and whether it makes a non-F-key safe to bind.
    private static let modifierTable:
        [(carbon: UInt32, flag: NSEvent.ModifierFlags, symbol: String, guards: Bool)] = [
            (UInt32(controlKey), .control, "⌃", true),
            (UInt32(optionKey), .option, "⌥", true),
            (UInt32(cmdKey), .command, "⌘", true),
            (UInt32(shiftKey), .shift, "⇧", false),
        ]

    /// Every modifier a hotkey can carry.
    public static let modifierMask = modifierTable.reduce(0) { $0 | $1.carbon }

    /// A key a hotkey can use: its name in a shortcut, and its menu key equivalent.
    struct Key {
        let name: String
        let menuKey: String
        /// An F-key, which types nothing, so it can stand alone.
        var isFunction = false
    }

    /// The keys a hotkey can use, by key code: letters and digits by their US-layout position,
    /// punctuation, Space, Return, Tab, Delete, the arrows and F1–F12. Esc is not one: it
    /// cancels recording.
    static let keys: [UInt32: Key] = {
        var keys: [UInt32: Key] = [:]
        func add(_ code: Int, _ name: String, _ menuKey: String? = nil) {
            keys[UInt32(code)] = Key(name: name, menuKey: menuKey ?? name.lowercased())
        }
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
        ]
        for (code, name) in letters { add(code, name) }
        add(kVK_Space, "Space", " ")
        add(kVK_Return, "↩", "\r")
        add(kVK_Tab, "⇥", "\t")
        add(kVK_Delete, "⌫", "\u{8}")
        func function(_ code: Int, _ name: String, _ key: Int) {
            add(code, name, String(UnicodeScalar(UInt16(key))!))
        }
        function(kVK_ForwardDelete, "⌦", NSDeleteFunctionKey)
        function(kVK_LeftArrow, "←", NSLeftArrowFunctionKey)
        function(kVK_RightArrow, "→", NSRightArrowFunctionKey)
        function(kVK_UpArrow, "↑", NSUpArrowFunctionKey)
        function(kVK_DownArrow, "↓", NSDownArrowFunctionKey)
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12,
        ]
        for (index, code) in functionKeys.enumerated() {
            function(code, "F\(index + 1)", NSF1FunctionKey + index)
            keys[UInt32(code)]?.isFunction = true
        }
        return keys
    }()

    /// Whether the key is one a hotkey can use.
    public var isKnownKey: Bool { Self.keys[keyCode] != nil }

    /// Whether the key is an F-key, which can stand alone: it types nothing.
    public var isFunctionKey: Bool { Self.keys[keyCode]?.isFunction == true }

    /// The menu-item key equivalent for this binding's key, empty for a key with no name.
    public var menuKey: String { Self.keys[keyCode]?.menuKey ?? "" }

    /// This binding's Carbon modifier mask as AppKit flags.
    public var modifierFlags: NSEvent.ModifierFlags {
        Self.modifierTable.reduce(into: []) { flags, m in
            if modifiers & m.carbon != 0 { flags.insert(m.flag) }
        }
    }

    /// Shows this binding as `item`'s key equivalent. Shown, not bound: the hotkey itself is
    /// global, so the menu never handles the press.
    @MainActor public func show(on item: NSMenuItem) {
        item.keyEquivalent = menuKey
        item.keyEquivalentModifierMask = modifierFlags
    }

    /// e.g. `⌘⇧4`
    public var display: String {
        Self.modifierTable.filter { modifiers & $0.carbon != 0 }.map(\.symbol).joined()
            + (Self.keys[keyCode]?.name ?? "key \(keyCode)")
    }

    /// The binding a key press makes: its key code, and its AppKit modifier flags as a Carbon
    /// mask (other flags, like Caps Lock, are ignored).
    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let modifiers = Self.modifierTable.reduce(0) {
            $0 | (flags.contains($1.flag) ? $1.carbon : 0)
        }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// The binding for a typed character and AppKit modifier flags, e.g. an editor key
    /// equivalent; nil for a character no hotkey key produces. Covers US key positions, as
    /// hotkeys do.
    public init?(character: String, flags: NSEvent.ModifierFlags) {
        guard let code = Self.keys.first(where: { $0.value.menuKey == character.lowercased() })?.key
        else { return nil }
        self.init(keyCode: UInt16(code), flags: flags)
    }

    /// True when the binding is allowed: an F-key alone, or any key with ⌘, ⌃ or ⌥. False for a
    /// bare or Shift-only letter, which would swallow that key system-wide.
    public var hasRequiredModifier: Bool {
        isFunctionKey || Self.modifierTable.contains { $0.guards && modifiers & $0.carbon != 0 }
    }

    /// `keyCode:modifiers`, as settings store it.
    public var stored: String { "\(keyCode):\(modifiers)" }

    /// nil unless `stored` is `keyCode:modifiers` naming a known key, only hotkey modifiers, and
    /// a modifier where one is needed, in canonical decimal (no sign, no leading zeros): settings are a file anyone can edit.
    public init?(stored: String) {
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let code = UInt32(parts[0]), let mask = UInt32(parts[1]),
            mask & ~Self.modifierMask == 0, Self.keys[code] != nil
        else { return nil }
        let binding = HotKeyBinding(keyCode: code, modifiers: mask)
        guard binding.hasRequiredModifier, binding.stored == stored else { return nil }
        self = binding
    }
}
