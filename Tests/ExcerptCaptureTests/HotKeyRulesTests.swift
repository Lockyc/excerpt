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

    @Test func anFKeyMayStandAlone() {
        let f6 = HotKeyBinding(keyCode: UInt32(kVK_F6), modifiers: 0)
        #expect(HotKeyRules.judge(f6, others: [:], system: []) == .accepted)
    }

    @Test func anUnnamedKeyIsRefused() {
        let escape = HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey))
        #expect(HotKeyRules.judge(escape, others: [:], system: []) == .unknownKey)
    }

    /// Recording, clearing and returning to the default are judged against every other action's
    /// binding and the reserved shortcuts, never against the action's own binding.
    @Test func anActionsNewHotkeyIsJudgedAgainstTheOthersAndTheReserved() {
        let bindings = ["Capture Area": four, "Capture Window": five]
        let copy = HotKeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        let reserved = ["Copy in the editor": copy]
        func judge(_ candidate: HotKeyBinding?) -> HotKeyVerdict {
            HotKeyRules.judge(
                candidate, for: "Capture Area", bindings: bindings, reserved: reserved, system: [])
        }
        #expect(judge(four) == .accepted)
        #expect(judge(five) == .taken(by: "Capture Window"))
        #expect(judge(copy) == .taken(by: "Copy in the editor"))
        #expect(judge(nil) == .accepted)
    }

    /// Default is judged like a recording: a default another action now holds is refused,
    /// naming it, so the action keeps its binding.
    @Test func aDefaultAnotherActionHoldsIsRefused() {
        let verdict = HotKeyRules.judge(
            four, for: "Capture Area", bindings: ["Capture Window": four], reserved: [:],
            system: [])
        #expect(verdict == .taken(by: "Capture Window"))
        #expect(!verdict.keeps)
    }

    /// The app-wide shortcuts every app answers are reserved, named as the editor's are.
    @Test func everyAppsOwnShortcutsAreReserved() {
        func binding(_ key: Int, _ modifiers: Int) -> HotKeyBinding {
            HotKeyBinding(keyCode: UInt32(key), modifiers: UInt32(modifiers))
        }
        #expect(
            HotKeyRules.appShortcuts == [
                "Quit in every app": binding(kVK_ANSI_Q, cmdKey),
                "Hide in every app": binding(kVK_ANSI_H, cmdKey),
                "Hide Others in every app": binding(kVK_ANSI_H, cmdKey | optionKey),
                "Minimize in every app": binding(kVK_ANSI_M, cmdKey),
                "Settings in every app": binding(kVK_ANSI_Comma, cmdKey),
            ])
        let quit = binding(kVK_ANSI_Q, cmdKey)
        let verdict = HotKeyRules.judge(
            quit, for: "Capture Fullscreen", bindings: [:], reserved: HotKeyRules.appShortcuts,
            system: [])
        #expect(verdict.message(for: quit) == "⌘Q is already Quit in every app")
    }

    /// Record Screen's default, ⌘⇧7, is free of the shortcuts every app answers and of the
    /// other actions' defaults.
    @Test func commandShiftSevenIsFree() {
        let seven = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_7), modifiers: HotKeyBinding.commandShift)
        let three = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_3), modifiers: HotKeyBinding.commandShift)
        let six = HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: HotKeyBinding.commandShift)
        let verdict = HotKeyRules.judge(
            seven, for: "Record Screen",
            bindings: [
                "Capture Window": three, "Capture Area": four, "Capture Text": five,
                "Choose Capture Mode…": six,
            ],
            reserved: HotKeyRules.appShortcuts, system: [])
        #expect(verdict == .accepted)
    }

    /// Review focus: settings are a file anyone can edit. Stored hotkeys are judged in action
    /// order as they are registered: a reserved, duplicated or unguarded one is refused, naming
    /// what holds it, and holds nothing itself.
    @Test func storedHotkeysAreJudgedInOrder() {
        let save = HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey))
        let bare = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        let verdicts = HotKeyRules.judgeStored(
            [
                ("Capture Area", save), ("Capture Window", four), ("Capture Text", four),
                ("Capture Fullscreen", bare), ("Choose Capture Mode…", five),
            ], reserved: ["Save in the editor": save])
        #expect(
            verdicts == [
                .taken(by: "Save in the editor"), .accepted, .taken(by: "Capture Window"),
                .needsModifier, .accepted,
            ])
    }
}
