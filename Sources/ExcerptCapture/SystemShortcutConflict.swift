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

/// True when an enabled system shortcut already owns this key + modifiers. Carbon's
/// RegisterEventHotKey does not see these, so the combination would register "successfully"
/// while the system acts on the press instead.
public func systemShortcutHolds(keyCode: UInt32, modifiers: UInt32, in table: [SymbolicHotKey])
    -> Bool
{
    table.contains { $0.enabled && $0.keyCode == keyCode && $0.modifiers == modifiers }
}
