import CoreGraphics
import Testing

@testable import ExcerptExport

@Suite struct ReadingOrderTests {
    @Test func runsOnOneLineReadLeftToRight() {
        let lines = ReadingOrder.lines([
            RecognizedText("world", CGRect(x: 120, y: 11, width: 60, height: 20)),
            RecognizedText("Hello", CGRect(x: 10, y: 10, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["Hello world"])
    }

    @Test func linesReadTopToBottomWhateverOrderTheyArrive() {
        let lines = ReadingOrder.lines([
            RecognizedText("third", CGRect(x: 10, y: 70, width: 60, height: 20)),
            RecognizedText("first", CGRect(x: 10, y: 10, width: 60, height: 20)),
            RecognizedText("second", CGRect(x: 10, y: 40, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["first", "second", "third"])
    }

    @Test func aSmallRunBesideATallOneJoinsItsLine() {
        let lines = ReadingOrder.lines([
            RecognizedText("Title", CGRect(x: 10, y: 0, width: 200, height: 40)),
            RecognizedText("v2", CGRect(x: 220, y: 22, width: 20, height: 12)),
        ])
        #expect(lines.map(\.text) == ["Title v2"])
    }

    @Test func blankRunsAreDropped() {
        let lines = ReadingOrder.lines([
            RecognizedText("  ", CGRect(x: 10, y: 10, width: 60, height: 20)),
            RecognizedText("kept", CGRect(x: 10, y: 40, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["kept"])
        #expect(ReadingOrder.lines([]).isEmpty)
    }

    @Test func aGapTallerThanALineIsAParagraphBreak() {
        let lines = ReadingOrder.lines([
            RecognizedText("one", CGRect(x: 10, y: 0, width: 60, height: 20)),
            RecognizedText("two", CGRect(x: 10, y: 28, width: 60, height: 20)),
            RecognizedText("three", CGRect(x: 10, y: 90, width: 60, height: 20)),
        ])
        #expect(ReadingOrder.text(lines) == ["one", "two", "", "three"])
    }
}
