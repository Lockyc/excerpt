import Carbon.HIToolbox
import Testing

@testable import ExcerptCapture

@Suite struct HotKeyRulesTests {
    let five = HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: HotKeyBinding.commandShift)
    let four = HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKeyBinding.commandShift)

    @Test func aFreeCombinationIsAccepted() {
        #expect(HotKeyRules.judge(five, others: ["Capture Area": four], system: []) == .accepted)
    }

    /// Review focus: a combination another binding holds is refused, naming the holder.
    @Test func anotherActionsBindingIsRefusedNamingIt() {
        let verdict = HotKeyRules.judge(four, others: ["Capture Area": four], system: [])
        #expect(verdict == .taken(by: "Capture Area"))
        #expect(!verdict.keeps)
        #expect(verdict.message(for: four) == "⌘⇧4 is already Capture Area")
    }

    /// Review focus: a combination an enabled macOS shortcut holds is kept and flagged; a
    /// disabled one is free.
    @Test func aMacOSShortcutIsKeptButFlagged() {
        let enabled = [
            SymbolicHotKey(keyCode: five.keyCode, modifiers: five.modifiers, enabled: true)
        ]
        let verdict = HotKeyRules.judge(five, others: [:], system: enabled)
        #expect(verdict == .heldBySystem)
        #expect(verdict.keeps)
        #expect(verdict.message(for: five)?.hasPrefix("⌘⇧5 is a macOS shortcut") == true)
        let disabled = [
            SymbolicHotKey(keyCode: five.keyCode, modifiers: five.modifiers, enabled: false)
        ]
        #expect(HotKeyRules.judge(five, others: [:], system: disabled) == .accepted)
    }

    @Test func aKeyWithoutCommandControlOrOptionIsRefused() {
        let shiftOnly = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        #expect(HotKeyRules.judge(shiftOnly, others: [:], system: []) == .needsModifier)
        let bare = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        #expect(HotKeyRules.judge(bare, others: [:], system: []) == .needsModifier)
        let control = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey))
        #expect(HotKeyRules.judge(control, others: [:], system: []) == .accepted)
    }

    /// Editor shortcuts reach `judge` among `others`, so a global hotkey can't take the press
    /// before the editor sees it.
    @Test func anEditorShortcutIsRefusedNamingTheCommand() {
        let forClaude = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_C), modifiers: HotKeyBinding.commandShift)
        let verdict = HotKeyRules.judge(
            forClaude, others: ["For Claude in the editor": forClaude], system: [])
        #expect(verdict == .taken(by: "For Claude in the editor"))
        #expect(verdict.message(for: forClaude) == "⌘⇧C is already For Claude in the editor")
    }

    @Test func anFKeyMayStandAlone() {
        let f6 = HotKeyBinding(keyCode: UInt32(kVK_F6), modifiers: 0)
        #expect(HotKeyRules.judge(f6, others: [:], system: []) == .accepted)
    }

    @Test func anUnnamedKeyIsRefused() {
        let escape = HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey))
        #expect(HotKeyRules.judge(escape, others: [:], system: []) == .unknownKey)
    }
}
