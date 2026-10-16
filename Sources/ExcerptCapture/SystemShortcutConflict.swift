/// One entry of macOS's symbolic hotkey table (`CopySymbolicHotKeys`), as plain values.
public struct SymbolicHotKey: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32  // Carbon modifier mask
    public let enabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

/// macOS's Touch Bar screenshot shortcuts (⌘⇧6 and ⌃⌘⇧6, key code 22). The table lists them as
/// enabled on every Mac, but only a Mac with a Touch Bar acts on them.
let touchBarShortcuts: Set<[UInt32]> = [[22, 768], [22, 4864]]

/// True when an enabled system shortcut already owns this key + modifiers. Carbon's
/// RegisterEventHotKey does not see these, so the combination would register "successfully"
/// while the system acts on the press instead. The Touch Bar screenshot shortcuts never count.
/// The table sets the fn bit on arrow- and F-key entries, which a binding never carries, so
/// only the bits a binding can hold are compared.
public func systemShortcutHolds(keyCode: UInt32, modifiers: UInt32, in table: [SymbolicHotKey])
    -> Bool
{
    guard !touchBarShortcuts.contains([keyCode, modifiers]) else { return false }
    return table.contains {
        $0.enabled && $0.keyCode == keyCode
            && $0.modifiers & HotKeyBinding.modifierMask == modifiers
    }
}
