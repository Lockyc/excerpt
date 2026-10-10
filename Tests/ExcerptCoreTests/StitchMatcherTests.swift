import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct StitchMatcherTests {
    let page = ScrollFixtures.page(width: 90, height: 1200)
    let header = ScrollFixtures.bar(width: 90, height: 24, tone: 60)
    let footer = ScrollFixtures.bar(width: 90, height: 16, tone: 140)

    /// The offset of a move; blank rows that happen to line up at the frame's edges may join
    /// the sticky rows, so tests of plain pages check the offset alone.
    func offset(_ match: FrameMatch) -> Int? {
        if case .moved(let offset, _, _) = match { offset } else { nil }
    }

    func frame(_ offset: Int, header: PixelBuffer? = nil, footer: PixelBuffer? = nil)
        -> PixelBuffer
    {
        ScrollFixtures.frame(page, offset: offset, viewport: 200, header: header, footer: footer)
    }

    @Test func findsTheOffset() {
        #expect(
            offset(StitchMatcher.match(frame(0), frame(120), ignoringRightColumns: 0)) == 120)
    }

    @Test func findsStickyHeaderAndFooter() {
        let match = StitchMatcher.match(
            frame(0, header: header, footer: footer), frame(97, header: header, footer: footer),
            ignoringRightColumns: 0)
        guard case .moved(let offset, let top, let bottom) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(offset == 97)
        #expect(top >= 24 && top < 30)  // the header, plus any blank rows that coincide
        #expect(bottom >= 16 && bottom < 22)
    }

    @Test func identicalFramesAreStill() {
        #expect(StitchMatcher.match(frame(40), frame(40), ignoringRightColumns: 0) == .still)
    }

    @Test func aSpinnerOnAStillPageIsStill() {
        let a = ScrollFixtures.animated(frame(40), x: 30, y: 80, width: 16, height: 16, phase: 1)
        let b = ScrollFixtures.animated(frame(40), x: 30, y: 80, width: 16, height: 16, phase: 2)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .still)
    }

    @Test func aScrollBarThumbMovingAloneIsStill() {
        let a = ScrollFixtures.animated(frame(40), x: 82, y: 10, width: 6, height: 30, phase: 1)
        let b = ScrollFixtures.animated(frame(40), x: 82, y: 50, width: 6, height: 30, phase: 1)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 10) == .still)
    }

    @Test func aScrollBarThumbDoesNotSpoilTheMatch() {
        let a = ScrollFixtures.animated(frame(0), x: 82, y: 10, width: 6, height: 60, phase: 1)
        let b = ScrollFixtures.animated(frame(120), x: 82, y: 40, width: 6, height: 60, phase: 1)
        #expect(
            offset(StitchMatcher.match(a, b, ignoringRightColumns: 10)) == 120)
    }

    @Test func aSmallAnimationThatScrollsWithThePageStillMatches() {
        // A spinner fixed to the page: it moves with the content and changes as it does. It
        // spoils its own rows of the overlap, a tenth of the evidence.
        let a = ScrollFixtures.animated(frame(0), x: 30, y: 150, width: 8, height: 8, phase: 1)
        let b = ScrollFixtures.animated(frame(120), x: 30, y: 30, width: 8, height: 8, phase: 2)
        #expect(
            offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 120)
    }

    @Test func aVideoThatScrollsWithThePageIsUncertain() {
        let a = ScrollFixtures.animated(frame(0), x: 4, y: 120, width: 80, height: 70, phase: 1)
        let b = ScrollFixtures.animated(frame(120), x: 4, y: 0, width: 80, height: 70, phase: 2)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func aDifferentPageIsUncertain() {
        // The user switched apps: the region now shows something unrelated.
        let other = ScrollFixtures.page(width: 90, height: 200, seed: 42)
        #expect(StitchMatcher.match(frame(0), other, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func movingMoreThanAFrameIsUncertain() {
        #expect(StitchMatcher.match(frame(0), frame(260), ignoringRightColumns: 0) == .uncertain)
    }

    @Test func framesOfDifferentSizesAreUncertain() {
        let short = ScrollFixtures.frame(page, offset: 0, viewport: 150)
        #expect(StitchMatcher.match(frame(0), short, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func repeatingRowsDoNotFoolTheMatcher() {
        let form = ScrollFixtures.form(width: 90, height: 1200)
        let a = ScrollFixtures.frame(form, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(form, offset: 120, viewport: 200)
        #expect(
            offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 120)
        // Counting matching rows instead of their share would pick the offset one field short:
        // its overlap is 40 rows longer and its box rows all match.
        let sa = RowSignatures(a, columns: 0..<90)
        let sb = RowSignatures(b, columns: 0..<90)
        let truth = StitchMatcher.counts(sa, sb, previousStart: 120, nextStart: 0, count: 80)
        let alias = StitchMatcher.counts(sa, sb, previousStart: 80, nextStart: 0, count: 120)
        #expect(alias.matches > truth.matches)
        #expect(truth.matches == truth.evidence)
    }

    @Test func rowsThatRepeatWithNothingUniqueAreUncertain() {
        let stripes = ScrollFixtures.stripes(width: 90, height: 1200)
        let a = ScrollFixtures.frame(stripes, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(stripes, offset: 125, viewport: 200)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func aStaticSidebarBesideAScrollingPaneStillMatches() {
        let sidebar = ScrollFixtures.page(width: 30, height: 200, seed: 9)
        let pane = ScrollFixtures.page(width: 90, height: 1200)
        let a = ScrollFixtures.beside(sidebar, ScrollFixtures.frame(pane, offset: 0, viewport: 200))
        let b = ScrollFixtures.beside(
            sidebar, ScrollFixtures.frame(pane, offset: 110, viewport: 200))
        #expect(
            offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 110)
    }

    @Test func theScrollBarStripIsSixteenPointsAtMostAnEighth() {
        #expect(StitchMatcher.ignoredRightColumns(width: 800, scale: 1) == 16)
        #expect(StitchMatcher.ignoredRightColumns(width: 800, scale: 2) == 32)
        #expect(StitchMatcher.ignoredRightColumns(width: 100, scale: 2) == 12)
        #expect(StitchMatcher.ignoredRightColumns(width: 4, scale: 2) == 0)
    }
}
