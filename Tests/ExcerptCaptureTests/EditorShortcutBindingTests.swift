import AppKit
import Carbon.HIToolbox
import ExcerptEditor
import Testing

@testable import ExcerptCapture

/// The app reserves the editor's shortcuts from hotkeys by mapping each through
/// `HotKeyBinding(character:flags:)`; a shortcut that failed to map would go unreserved.
@Suite struct EditorShortcutBindingTests {
    @Test func everyEditorShortcutMapsToABinding() {
        let bindings = EditorShortcut.allCases.map {
            HotKeyBinding(character: $0.key, flags: $0.modifiers)
        }
        #expect(!bindings.contains(nil))
        #expect(Set(bindings.compactMap { $0 }).count == EditorShortcut.allCases.count)
        #expect(
            bindings.contains(
                HotKeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: HotKeyBinding.commandShift)))
    }
}
