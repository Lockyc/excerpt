import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct GapSnapperTests {
    // sheet(): grey gridlines at y % 20 == 0 and x % 60 == 0 cross every cell row and column,
    // so — as in a real spreadsheet — the only uniform lines are the gridlines themselves.
    let sheet = PixelBuffer(Fixtures.sheet(width: 360, height: 200))

    @Test func uniformLineSnapsToItself() {
        #expect(GapSnapper.snap(40, axis: .horizontal, in: sheet, radius: 12) == 40)
    }

    @Test func nonUniformSnapsToNearestPreferringLowerOnTie() {
        #expect(GapSnapper.snap(42, axis: .horizontal, in: sheet, radius: 12) == 40)
        // 30 is 10 from both 20 and 40: the lower wins.
        #expect(GapSnapper.snap(30, axis: .horizontal, in: sheet, radius: 12) == 20)
        // 33 → 40 is 7 away, 20 is 13 away.
        #expect(GapSnapper.snap(33, axis: .horizontal, in: sheet, radius: 12) == 40)
    }

    @Test func nothingInRadiusKeepsThePosition() {
        #expect(GapSnapper.snap(30, axis: .horizontal, in: sheet, radius: 5) == 30)
    }

    @Test func columnsSnapToo() {
        // 100 → 120 is 20 away, 60 is 40 away.
        #expect(GapSnapper.snap(100, axis: .vertical, in: sheet, radius: 25) == 120)
    }

    @Test func clampsAtTheEdges() {
        #expect(GapSnapper.snap(-4, axis: .horizontal, in: sheet, radius: 3) == 0)
        #expect(GapSnapper.snap(500, axis: .horizontal, in: sheet, radius: 3) == 199)
    }
}
