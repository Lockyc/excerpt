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

@Suite struct ColumnTests {
    /// Runs `height` high, one per y, from `x` to `x + 100`, named `prefix` and their index.
    static func column(_ prefix: String, x: Int, ys: [Int], height: Int = 20) -> [RecognizedText] {
        ys.enumerated().map { index, y in
            RecognizedText("\(prefix)\(index + 1)", CGRect(x: x, y: y, width: 100, height: height))
        }
    }

    static func texts(_ blocks: [[TextLine]]) -> [[String]] { blocks.map { $0.map(\.text) } }

    /// A menu over a terminal: two panes on different backgrounds whose lines are spaced
    /// differently, so they only meet by chance.
    static let menu = column("m", x: 10, ys: [0, 32, 64, 96])
    static let terminal = column("t", x: 300, ys: [12, 34, 56, 78, 100])

    @Test func panesOnDifferentBackgroundsReadOneThenTheOther() {
        var asked: [(Range<Int>, Range<Int>)] = []
        let blocks = ReadingOrder.blocks(Self.menu + Self.terminal) { gutter, rows in
            asked.append((gutter, rows))
            return gutter.contains(200)
        }
        #expect(
            Self.texts(blocks) == [["m1", "m2", "m3", "m4"], ["t1", "t2", "t3", "t4", "t5"]])
        #expect(asked.contains { $0.0 == 110..<300 && $0.1 == 0..<120 })
    }

    @Test func panesOnOneBackgroundReadRowByRow() {
        let blocks = ReadingOrder.blocks(Self.menu + Self.terminal) { _, _ in false }
        #expect(blocks.count == 1)
        #expect(blocks[0].first?.text == "m1")
    }

    @Test func rowsThatLineUpStayWholeAcrossAChangedBackground() {
        // A spreadsheet's shaded row numbers beside its cells.
        let numbers = Self.column("", x: 0, ys: [0, 30, 60, 90])
        let cells = Self.column("cell", x: 200, ys: [1, 31, 59, 90])
        let blocks = ReadingOrder.blocks(numbers + cells) { _, _ in true }
        #expect(Self.texts(blocks) == [["1 cell1", "2 cell2", "3 cell3", "4 cell4"]])
    }

    @Test func aGapNarrowerThanALineIsNotAGutter() {
        let left = Self.column("a", x: 0, ys: [0, 32, 64])
        let right = Self.column("b", x: 110, ys: [14, 46])
        #expect(ReadingOrder.blocks(left + right) { _, _ in true }.count == 1)
    }

    @Test func aBarAcrossTheTopIsReadBeforeThePanes() {
        let bar = RecognizedText("bar", CGRect(x: 0, y: -40, width: 420, height: 20))
        let blocks = ReadingOrder.blocks([bar] + Self.menu + Self.terminal) { _, _ in true }
        #expect(
            Self.texts(blocks) == [
                ["bar"], ["m1", "m2", "m3", "m4"], ["t1", "t2", "t3", "t4", "t5"],
            ])
    }

    @Test func linesAboveAndBelowPanesJoinTheirNeighbours() {
        let above = Self.column("above", x: 0, ys: [-70, -40])
        let below = Self.column("below", x: 0, ys: [150])
        // Only the panes' own rows change background across the gutter.
        let blocks = ReadingOrder.blocks(above + Self.menu + Self.terminal + below) { _, rows in
            rows.lowerBound >= 0 && rows.upperBound <= 120
        }
        #expect(Self.texts(blocks).first == ["above1", "above2"])
        #expect(Self.texts(blocks).last == ["below1"])
        #expect(blocks.count == 4)
    }

    @Test func blocksAreWrittenWithABlankLineBetween() {
        let blocks = ReadingOrder.blocks(Self.menu + Self.terminal) { _, _ in true }
        #expect(
            ReadingOrder.text(blocks: blocks) == [
                "m1", "m2", "m3", "m4", "", "t1", "t2", "t3", "t4", "t5",
            ])
        #expect(ReadingOrder.blocks([]) { _, _ in true }.isEmpty)
    }
}
