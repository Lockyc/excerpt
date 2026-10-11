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
            "\(binding.display) is a macOS shortcut"
        case .taken(let action): "\(binding.display) is already \(action)"
        case .needsModifier: "Add ⌘, ⌃ or ⌥: \(binding.display) alone would block typing it"
        case .unknownKey: "That key can't be a hotkey"
        }
    }
}

public enum HotKeyRules {
    /// The shortcuts every app answers, by title (`Quit in every app`), which no action may
    /// take: a global hotkey would get the press before any app saw it.
    public static let appShortcuts: [String: HotKeyBinding] = [
        "Quit in every app": HotKeyBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)),
        "Hide in every app": HotKeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)),
        "Hide Others in every app": HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey)),
        "Minimize in every app": HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)),
        "Settings in every app": HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey)),
    ]

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

    /// Judges the stored hotkeys as they are registered, in action order: each against the
    /// `reserved` shortcuts and the ones kept before it, so a hand-edited setting can't take a
    /// reserved or duplicated combination. A refused hotkey is not registered and holds nothing.
    /// macOS's shortcuts are left to the registration's own state.
    public static func judgeStored(
        _ stored: [(action: String, binding: HotKeyBinding)], reserved: [String: HotKeyBinding]
    ) -> [HotKeyVerdict] {
        var kept = reserved
        return stored.map { action, binding in
            let verdict = judge(binding, others: kept, system: [])
            if verdict.keeps { kept[action] = binding }
            return verdict
        }
    }
}
