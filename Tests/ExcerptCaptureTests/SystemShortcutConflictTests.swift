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
    @Test func touchBarScreenshotShortcutsAreNotAConflict() {
        let touchBar = [
            SymbolicHotKey(keyCode: 22, modifiers: 768, enabled: true),
            SymbolicHotKey(keyCode: 22, modifiers: 4864, enabled: true),
        ]
        #expect(!systemShortcutHolds(keyCode: 22, modifiers: 768, in: touchBar))
        #expect(!systemShortcutHolds(keyCode: 22, modifiers: 4864, in: touchBar))
    }
}
