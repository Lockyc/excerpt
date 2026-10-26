/// The modifier keys a logged shortcut can carry.
public struct KeyModifiers: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// Decides which key presses a recording logs and what the shortcut pill says. A plain or
/// shifted character is never logged, so typed text never reaches the event log.
public enum ShortcutFilter {
    /// Virtual key codes (Carbon's `kVK_*`, which Core cannot import) mapped to their glyphs.
    private enum Key {
        static let space: UInt16 = 0x31
        static let named: [UInt16: String] = [
            0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x35: "⎋", 0x33: "⌫", 0x75: "⌦",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        ]
    }

    /// The pill text for a press, or nil when it must not be logged. Modifiers come in macOS
    /// order (⌃⌥⇧⌘) before the key. `character` is `charactersIgnoringModifiers`.
    public static func label(keyCode: UInt16, modifiers: KeyModifiers, character: String?)
        -> String?
    {
        let named = Key.named[keyCode]
        let chorded = !modifiers.isDisjoint(with: [.command, .control, .option])
        guard named != nil || chorded else { return nil }

        let key: String
        if let named {
            key = named
        } else if keyCode == Key.space {
            key = "␣"
        } else if let character, !character.isEmpty {
            key = character.uppercased()
        } else {
            return nil
        }

        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + key
    }
}
