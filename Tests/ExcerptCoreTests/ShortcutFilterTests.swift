import Testing

@testable import ExcerptCore

@Suite struct ShortcutFilterTests {
    /// Typed text never reaches the event log: over every key code, every printable ASCII
    /// character and the characters ⌥ types on common layouts, and every set of ⌥ and ⇧, the
    /// label is what the key alone would log, never the character.
    @Test func noCharacterLogsWithoutCommandOrControl() {
        let typed =
            (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }
            + ["£", "–", "—", "€", "©", "π", "å", "ß", "∑", "…", "é", "ü"]
        let typing: [KeyModifiers] = [[], [.option], [.shift], [.option, .shift]]
        for keyCode in UInt16(0)...0x7F {
            for modifiers in typing {
                let key = ShortcutFilter.label(
                    keyCode: keyCode, modifiers: modifiers, character: nil)
                for character in typed {
                    let label = ShortcutFilter.label(
                        keyCode: keyCode, modifiers: modifiers, character: character)
                    #expect(
                        label == key,
                        "key \(keyCode), modifiers \(modifiers.rawValue), \(character)")
                }
            }
        }
    }
    @Test func plainAndShiftedCharactersAreNeverLogged() {
        #expect(ShortcutFilter.label(keyCode: 0x00, modifiers: [], character: "A") == nil)
        #expect(ShortcutFilter.label(keyCode: 0x00, modifiers: [.shift], character: "A") == nil)
        #expect(ShortcutFilter.label(keyCode: 0x31, modifiers: [], character: " ") == nil)  // space
    }

    @Test func modifierCombinationsAreLogged() {
        #expect(
            ShortcutFilter.label(keyCode: 0x28, modifiers: [.command, .shift], character: "K")
                == "⇧⌘K")
        #expect(
            ShortcutFilter.label(keyCode: 0x28, modifiers: [.control, .option], character: "k")
                == "⌃⌥K")
        #expect(ShortcutFilter.label(keyCode: 0x33, modifiers: [.command], character: nil) == "⌘⌫")
        #expect(
            ShortcutFilter.label(
                keyCode: 0x00, modifiers: [.command, .control, .option, .shift], character: "a")
                == "⌃⌥⇧⌘A")
    }

    /// ⌥ and ⌥⇧ type characters (`@`, `{`, `£`, `–` on common layouts), so they log only a
    /// named key.
    @Test func optionAloneIsTypingUnlessTheKeyIsNamed() {
        #expect(ShortcutFilter.label(keyCode: 0x25, modifiers: [.option], character: "l") == nil)
        #expect(
            ShortcutFilter.label(keyCode: 0x13, modifiers: [.option, .shift], character: "2")
                == nil)
        #expect(ShortcutFilter.label(keyCode: 0x7B, modifiers: [.option], character: nil) == "⌥←")
    }

    @Test func navigationKeysAreLoggedAloneOrShifted() {
        #expect(ShortcutFilter.label(keyCode: 0x24, modifiers: [], character: nil) == "↩")
        #expect(ShortcutFilter.label(keyCode: 0x35, modifiers: [], character: nil) == "⎋")
        #expect(ShortcutFilter.label(keyCode: 0x30, modifiers: [], character: nil) == "⇥")
        #expect(ShortcutFilter.label(keyCode: 0x7C, modifiers: [.shift], character: nil) == "⇧→")
        #expect(ShortcutFilter.label(keyCode: 0x60, modifiers: [], character: nil) == "F5")
        #expect(ShortcutFilter.label(keyCode: 0x73, modifiers: [], character: nil) == "↖")  // Home
    }

    @Test func everyFunctionKeyIsLogged() {
        let codes: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
        ]
        for (index, code) in codes.enumerated() {
            #expect(
                ShortcutFilter.label(keyCode: code, modifiers: [], character: nil)
                    == "F\(index + 1)")
        }
    }
}
