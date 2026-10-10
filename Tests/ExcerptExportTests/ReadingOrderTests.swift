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

    @Test func aTallRunDoesNotChainTwoLinesTogether() {
        let lines = ReadingOrder.lines([
            RecognizedText("small one", CGRect(x: 100, y: 0, width: 60, height: 20)),
            RecognizedText("Heading", CGRect(x: 10, y: 0, width: 80, height: 100)),
            RecognizedText("small two", CGRect(x: 100, y: 80, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["Heading small one", "small two"])
    }

    @Test func aRaisedMarkerStaysOnItsLine() {
        let lines = ReadingOrder.lines([
            RecognizedText("note", CGRect(x: 10, y: 20, width: 40, height: 20)),
            RecognizedText("1", CGRect(x: 52, y: 16, width: 8, height: 10)),
            RecognizedText("next", CGRect(x: 10, y: 50, width: 40, height: 20)),
        ])
        #expect(lines.map(\.text) == ["note 1", "next"])
    }

    @Test func offsetBaselinesInATableRowStayOneLine() {
        let lines = ReadingOrder.lines([
            RecognizedText("a", CGRect(x: 10, y: 10, width: 30, height: 20)),
            RecognizedText("b", CGRect(x: 100, y: 14, width: 30, height: 20)),
            RecognizedText("c", CGRect(x: 200, y: 7, width: 30, height: 20)),
        ])
        #expect(lines.map(\.text) == ["a b c"])
    }

    @Test func aGapExactlyOneLineHighIsNotAParagraphBreak() {
        let lines = ReadingOrder.lines([
            RecognizedText("one", CGRect(x: 10, y: 0, width: 60, height: 20)),
            RecognizedText("two", CGRect(x: 10, y: 40, width: 60, height: 20)),
            RecognizedText("three", CGRect(x: 10, y: 81, width: 60, height: 20)),
        ])
        #expect(ReadingOrder.text(lines) == ["one", "two", "", "three"])
    }

    @Test func nonFiniteBoundsAreDropped() {
        let lines = ReadingOrder.lines([
            RecognizedText("bad", CGRect(x: CGFloat.nan, y: 10, width: 60, height: 20)),
            RecognizedText("inf", CGRect(x: 0, y: 10, width: CGFloat.infinity, height: 20)),
            RecognizedText("ok", CGRect(x: 10, y: 10, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["ok"])
    }

    @Test func newlinesInsideARunBecomeSpaces() {
        let lines = ReadingOrder.lines([
            RecognizedText("\n", CGRect(x: 10, y: 0, width: 60, height: 20)),
            RecognizedText("a\nb", CGRect(x: 10, y: 40, width: 60, height: 20)),
        ])
        #expect(lines.map(\.text) == ["a b"])
    }

    @Test func noLinesWriteNothingAndACustomWriterIsUsed() {
        #expect(ReadingOrder.text([]).isEmpty)
        let lines = ReadingOrder.lines([
            RecognizedText("x", CGRect(x: 10, y: 0, width: 60, height: 20))
        ])
        #expect(ReadingOrder.text(lines, write: { "> " + $0.text }) == ["> x"])
    }
}
