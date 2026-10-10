import AppKit
import Carbon.HIToolbox
import Testing

@testable import ExcerptCapture

@Suite struct HotKeyBindingTests {
    @Test func displaysModifiersInMenuOrderThenTheKey() {
        #expect(
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKeyBinding.commandShift)
                .display == "⌘⇧4")
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        #expect(HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: all).display == "⌃⌥⌘⇧T")
        #expect(HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: 0).display == "F5")
        #expect(
            HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).display
                == "⌥Space")
        #expect(HotKeyBinding(keyCode: 0xFF, modifiers: 0).display == "key 255")
    }

    /// The editor's key equivalents (characters + flags) all map to bindings.
    @Test func aTypedCharacterWithFlagsMakesABinding() {
        for key in ["s", "c", "w", "x", "v", "a", "z"] {
            #expect(HotKeyBinding(character: key, flags: [.command]) != nil)
        }
        let forClaude = HotKeyBinding(character: "c", flags: [.command, .shift])
        #expect(forClaude?.display == "⌘⇧C")
        #expect(forClaude?.keyCode == UInt32(kVK_ANSI_C))
        #expect(HotKeyBinding(character: "é", flags: [.command]) == nil)
    }

    @Test func menuKeysAreWhatAMenuItemTakes() {
        #expect(HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: 0).menuKey == "t")
        #expect(HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: 0).menuKey == "5")
        #expect(
            HotKeyBinding(keyCode: UInt32(kVK_F1), modifiers: 0).menuKey
                == String(UnicodeScalar(UInt16(NSF1FunctionKey))!))
        #expect(HotKeyBinding(keyCode: 0xFF, modifiers: 0).menuKey == "")
    }

    @Test func aKeyPressBecomesABinding() {
        let binding = HotKeyBinding(
            keyCode: UInt16(kVK_ANSI_5), flags: [.command, .shift, .capsLock])
        #expect(
            binding
                == HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: HotKeyBinding.commandShift)
        )
        #expect(binding.modifierFlags == [.command, .shift])
    }

    @Test func theStoredFormRoundTripsAndRefusesNonsense() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_6), modifiers: HotKeyBinding.commandShift)
        #expect(binding.stored == "22:768")
        #expect(HotKeyBinding(stored: binding.stored) == binding)
        for bad in [
            "", "22", "22:", ":768", "x:768", "22:768:1", "255:768", "22:1", "-1:768", "0:0",
            "0:512",
        ] {
            #expect(HotKeyBinding(stored: bad) == nil, "\(bad)")
        }
    }

    @Test func onlyFKeysAreFunctionKeys() {
        #expect(HotKeyBinding(keyCode: UInt32(kVK_F12), modifiers: 0).isFunctionKey)
        #expect(!HotKeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: 0).isFunctionKey)
        #expect(!HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: 0).isKnownKey)
    }
}

@Suite struct HotKeyNeedsModifierTests {
    @Test func aBareOrShiftOnlyLetterNeedsAModifier() {
        let a = UInt32(kVK_ANSI_A)
        #expect(!HotKeyBinding(keyCode: a, modifiers: 0).hasRequiredModifier)
        #expect(!HotKeyBinding(keyCode: a, modifiers: UInt32(shiftKey)).hasRequiredModifier)
        for m in [cmdKey, controlKey, optionKey] {
            #expect(HotKeyBinding(keyCode: a, modifiers: UInt32(m)).hasRequiredModifier)
        }
        #expect(HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: 0).hasRequiredModifier)
    }
}
