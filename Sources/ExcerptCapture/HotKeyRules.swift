import Carbon.HIToolbox

/// What a newly recorded hotkey would do, before it replaces the old one.
public enum HotKeyVerdict: Equatable, Sendable {
    /// Free to use.
    case accepted
    /// Usable, but an enabled macOS shortcut holds the same keys, so the press goes to macOS
    /// until that shortcut is turned off. Kept, and flagged wherever the hotkey is shown.
    case heldBySystem
    /// Another of excerpt's actions has it.
    case taken(by: String)
    /// No ⌘, ⌃ or ⌥: as a global hotkey it would swallow that key everywhere.
    case needsModifier
    /// A key excerpt can't name or show in a menu.
    case unknownKey

    /// Whether the binding is saved.
    public var keeps: Bool { self == .accepted || self == .heldBySystem }

    /// What Settings says about `binding` under this verdict; nil when there is nothing to say.
    public func message(for binding: HotKeyBinding) -> String? {
        switch self {
        case .accepted: nil
        case .heldBySystem:
            "\(binding.display) is a macOS shortcut: turn it off in System Settings → Keyboard → Keyboard Shortcuts for Excerpt to get it"
        case .taken(let action): "\(binding.display) is already \(action)"
        case .needsModifier: "Add ⌘, ⌃ or ⌥: \(binding.display) alone would block typing it"
        case .unknownKey: "That key can't be a hotkey"
        }
    }
}

public enum HotKeyRules {
    /// Judges `candidate` for an action. `others` are the other actions' current bindings by
    /// title; `system` is macOS's symbolic hotkey table.
    public static func judge(
        _ candidate: HotKeyBinding, others: [String: HotKeyBinding], system: [SymbolicHotKey]
    ) -> HotKeyVerdict {
        guard candidate.isKnownKey else { return .unknownKey }
        guard candidate.hasRequiredModifier else { return .needsModifier }
        if let holder = others.filter({ $0.value == candidate }).keys.sorted().first {
            return .taken(by: holder)
        }
        return systemShortcutHolds(
            keyCode: candidate.keyCode, modifiers: candidate.modifiers, in: system)
            ? .heldBySystem : .accepted
    }

    /// Judges `candidate` as the hotkey of the action titled `action`, against every other
    /// action's binding in `bindings` and the `reserved` shortcuts, all by title. Recording a
    /// hotkey, clearing one and returning one to its default all go through here. No hotkey
    /// (nil) is always accepted.
    public static func judge(
        _ candidate: HotKeyBinding?, for action: String, bindings: [String: HotKeyBinding],
        reserved: [String: HotKeyBinding], system: [SymbolicHotKey]
    ) -> HotKeyVerdict {
        guard let candidate else { return .accepted }
        let others = bindings.filter { $0.key != action }
            .merging(reserved) { binding, _ in binding }
        return judge(candidate, others: others, system: system)
    }
}
