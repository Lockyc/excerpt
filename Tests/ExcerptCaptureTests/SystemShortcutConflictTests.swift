import Testing

@testable import ExcerptCapture

@Suite struct SystemShortcutConflictTests {
    private let table = [
        SymbolicHotKey(keyCode: 21, modifiers: 768, enabled: true),
        SymbolicHotKey(keyCode: 20, modifiers: 768, enabled: false),
    ]

    @Test func enabledMatchIsAConflict() {
        #expect(systemShortcutHolds(keyCode: 21, modifiers: 768, in: table))
    }
    @Test func disabledEntryIsNotAConflict() {
        #expect(!systemShortcutHolds(keyCode: 20, modifiers: 768, in: table))
    }
    @Test func differentModifiersAreNotAConflict() {
        #expect(!systemShortcutHolds(keyCode: 21, modifiers: 4864, in: table))
    }
    @Test func theFnBitOnArrowAndFKeyEntriesIsIgnored() {
        let table = [
            SymbolicHotKey(keyCode: 126, modifiers: 0x21000, enabled: true),  // ⌃↑ Mission Control
            SymbolicHotKey(keyCode: 103, modifiers: 0x20000, enabled: true),  // F11 Show Desktop
        ]
        #expect(systemShortcutHolds(keyCode: 126, modifiers: 0x1000, in: table))
        #expect(systemShortcutHolds(keyCode: 103, modifiers: 0, in: table))
    }
    @Test func touchBarScreenshotShortcutsAreNotAConflict() {
        let touchBar = [
            SymbolicHotKey(keyCode: 22, modifiers: 768, enabled: true),
            SymbolicHotKey(keyCode: 22, modifiers: 4864, enabled: true),
        ]
        #expect(!systemShortcutHolds(keyCode: 22, modifiers: 768, in: touchBar))
        #expect(!systemShortcutHolds(keyCode: 22, modifiers: 4864, in: touchBar))
    }
}
