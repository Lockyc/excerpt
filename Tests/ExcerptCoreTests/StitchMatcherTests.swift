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
        if case .moved(let offset, _, _, _) = match { offset } else { nil }
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
        guard case .moved(let offset, let top, let bottom, _) = match else {
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
        // its overlap is 40 rows longer and its box rows all match. Box rows repeat in every
        // field, so they are no evidence: only the unique label rows count, and both offsets
        // are scored on those alone.
        let sa = RowSignatures(a, columns: 0..<90)
        let sb = RowSignatures(b, columns: 0..<90)
        let ua = StitchMatcher.uniqueRows(sa, in: 0..<200)
        let ub = StitchMatcher.uniqueRows(sb, in: 0..<200)
        let truth = StitchMatcher.counts(
            sa, sb, previousStart: 120, nextStart: 0, count: 80, previousUnique: ua,
            nextUnique: ub)
        let alias = StitchMatcher.counts(
            sa, sb, previousStart: 80, nextStart: 0, count: 120, previousUnique: ua,
            nextUnique: ub)
        #expect(truth.matches == truth.evidence)
        #expect(alias.matches < alias.evidence)
    }

    @Test func cardsMovedMoreThanAFrameAreUncertain() {
        // Only an alias one card away overlaps, and its box rows all match: repeated rows can't
        // pin an offset, so no seam is guessed.
        let cards = ScrollFixtures.form(width: 90, height: 1500, period: 150)
        let a = ScrollFixtures.frame(cards, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(cards, offset: 315, viewport: 200)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func zeroWidthFramesAreUncertain() {
        let empty = PixelBuffer(width: 0, height: 5, bytes: [])
        #expect(StitchMatcher.match(empty, empty, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func aCaretBlinkingOnABlankPageIsStill() {
        let blank = ScrollFixtures.paint(width: 90, height: 200) { _, _ in ScrollFixtures.paper }
        let caret = ScrollFixtures.paint(width: 90, height: 200) { x, y in
            (20..<22).contains(x) && (50..<66).contains(y)
                ? ScrollFixtures.ink : ScrollFixtures.paper
        }
        #expect(StitchMatcher.match(blank, caret, ignoringRightColumns: 0) == .still)
    }

    @Test func aSmallMoveOfWideLinesOnASparsePageIsNeverStill() {
        func lines(shift: Int) -> PixelBuffer {
            ScrollFixtures.paint(width: 90, height: 200) { x, y in
                [40, 80, 120].contains { (y - shift) >= $0 && (y - shift) < $0 + 2 }
                    && x >= 4 && x < 86 ? ScrollFixtures.ink : ScrollFixtures.paper
            }
        }
        #expect(
            StitchMatcher.match(lines(shift: 0), lines(shift: -2), ignoringRightColumns: 0)
                != .still)
    }

    @Test func aTinyGlyphMovingOnABlankPageReadsStill() {
        // The documented limit: a patch this small is indistinguishable from a caret.
        func glyph(at y: Int) -> PixelBuffer {
            ScrollFixtures.paint(width: 90, height: 200) { x, row in
                (20..<22).contains(x) && (y..<(y + 8)).contains(row)
                    ? ScrollFixtures.ink : ScrollFixtures.paper
            }
        }
        #expect(
            StitchMatcher.match(glyph(at: 50), glyph(at: 52), ignoringRightColumns: 0) == .still)
    }

    /// A long page where `block` rows at `phase` repeat every 250 rows, so the frame one period
    /// further on aliases the true offset; everything else is unique text.
    func repeating(phase: Int, block: Int) -> PixelBuffer {
        let base = ScrollFixtures.page(width: 90, height: 1500, seed: 3)
        return ScrollFixtures.paint(width: 90, height: 1500) { x, y in
            let row = y % 250
            guard (phase..<(phase + block)).contains(row) else { return base[x: x, y: y] }
            return base[x: x, y: row]
        }
    }

    @Test func aLongRepeatedBlockWithTextAroundItIsUncertain() {
        // The alias one period away matches the block's rows; the rows around it differ in
        // full-width text, which is different content, not animation.
        let long = repeating(phase: 60, block: 140)
        let a = ScrollFixtures.frame(long, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(long, offset: 300, viewport: 200)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func aRepeatedBlockWithAShortUniqueLabelIsUncertain() {
        // Blank page, a 50-row block repeated every 250 rows, a 3-row label unique to each
        // block and ten rows of text: the alias matches the block and mismatches the 13 rows
        // of different content.
        let base = ScrollFixtures.page(width: 90, height: 1500, seed: 3)
        let long = ScrollFixtures.paint(width: 90, height: 1500) { x, y in
            switch y % 250 {
            case 100..<150: base[x: x, y: 100 + (y % 250 - 100)]
            case 60..<63, 200..<210: base[x: x, y: y]
            default: ScrollFixtures.paper
            }
        }
        let a = ScrollFixtures.frame(long, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(long, offset: 280, viewport: 200)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func knownLimitContentDifferingOnlyInASmallPatchReadsAsAMove() {
        // Pinned limitation. A blank page repeats a 100-row block every 250 rows, with a label
        // that differs between blocks only in a 5-column patch. The pair a frame-plus-30
        // apart is indistinguishable by pixels from an honest small move with a local
        // animation, so it reads moved(30). Auto mode closes this with an expected-travel
        // check (Task 7).
        let base = ScrollFixtures.page(width: 90, height: 1500, seed: 3)
        let long = ScrollFixtures.paint(width: 90, height: 1500) { x, y in
            let row = y % 250
            switch row {
            case 100..<200: return base[x: x, y: row]
            case 60..<63:
                let patch = (40..<45).contains(x)
                return base[x: x, y: patch ? y : row]
            default: return ScrollFixtures.paper
            }
        }
        let a = ScrollFixtures.frame(long, offset: 0, viewport: 200)
        let b = ScrollFixtures.frame(long, offset: 280, viewport: 200)
        #expect(offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 30)
    }

    @Test func anHonestMoveWithALocalAnimationIsStillFound() {
        let a = ScrollFixtures.animated(frame(0), x: 30, y: 100, width: 10, height: 10, phase: 1)
        let b = ScrollFixtures.animated(frame(150), x: 30, y: 60, width: 10, height: 10, phase: 2)
        #expect(offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 150)
    }

    @Test func aTrueOverlapWithTooFewEvidenceRowsIsUncertain() {
        // 5 rows overlap: fewer than the 8 evidence rows a move needs.
        #expect(StitchMatcher.match(frame(0), frame(195), ignoringRightColumns: 0) == .uncertain)
    }

    @Test func stillWinsANearTieAgainstAScoredMove() {
        // A 12-row pane scrolls by 2 inside a static 1000-row page: the move scores 1.0, the
        // page scores 0.988; within the margin, so no seam.
        let base = ScrollFixtures.page(width: 90, height: 1000)
        let pane = ScrollFixtures.page(width: 90, height: 40, seed: 5)
        func frame(_ offset: Int) -> PixelBuffer {
            ScrollFixtures.stack([
                ScrollFixtures.rows(base, 0..<494),
                ScrollFixtures.rows(pane, offset..<(offset + 12)),
                ScrollFixtures.rows(base, 506..<1000),
            ])
        }
        #expect(StitchMatcher.match(frame(0), frame(2), ignoringRightColumns: 0) == .still)
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

    /// A 150-column frame: a 30-column side panel on each side of the 90-column page.
    func panelled(page pageOffset: Int, panels panelOffset: Int) -> PixelBuffer {
        let left = ScrollFixtures.page(width: 30, height: 1200, seed: 2)
        let right = ScrollFixtures.page(width: 30, height: 1200, seed: 3)
        return ScrollFixtures.beside(
            ScrollFixtures.beside(
                ScrollFixtures.frame(left, offset: panelOffset, viewport: 200),
                frame(pageOffset)),
            ScrollFixtures.frame(right, offset: panelOffset, viewport: 200))
    }

    @Test func sidePanelsMovingByAnotherAmountLeaveThePageTheBand() {
        // Sticky panels still pinning: they moved 40 rows while the page moved 120.
        let match = StitchMatcher.match(
            panelled(page: 0, panels: 0), panelled(page: 120, panels: 40),
            ignoringRightColumns: 0)
        guard case .moved(let offset, _, _, let columns) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(offset == 120)
        // Inside the page (marks from 34 to 116), clear of every marked panel column (left marks
        // end at 26, right ones start at 124), and at least a third of the width.
        #expect(columns.lowerBound >= 26 && columns.upperBound <= 124)
        #expect(columns.count >= 50)
    }

    @Test func aWholeWidthMoveIsItsOwnBand() {
        let match = StitchMatcher.match(frame(0), frame(120), ignoringRightColumns: 0)
        guard case .moved(_, _, _, let columns) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(columns.count >= 80)  // the changed span: the page's marked columns
    }

    @Test func aNarrowScrollingBandIsNotBelieved() {
        // 40 scrolling columns beside 110 of video: a band under a third of the width.
        let video = ScrollFixtures.paint(width: 110, height: 200) { _, _ in ScrollFixtures.paper }
        let a = ScrollFixtures.beside(
            ScrollFixtures.animated(video, x: 0, y: 0, width: 110, height: 200, phase: 1),
            ScrollFixtures.columns(frame(0), 0..<40))
        let b = ScrollFixtures.beside(
            ScrollFixtures.animated(video, x: 0, y: 0, width: 110, height: 200, phase: 2),
            ScrollFixtures.columns(frame(120), 0..<40))
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
    }

    @Test func anAnimationAtThePagesEdgeIsUncertainNotABand() {
        // A video over the page's right 40 columns: the rest moves as one and is over a third
        // of the width, but the video's columns neither move with it nor by any offset of
        // their own. Stitching the rest would erase what the video covers.
        let page = ScrollFixtures.page(width: 110, height: 1200)
        func shot(_ offset: Int, phase: Int) -> PixelBuffer {
            ScrollFixtures.animated(
                ScrollFixtures.frame(page, offset: offset, viewport: 200), x: 70, y: 0,
                width: 40, height: 200, phase: phase)
        }
        #expect(
            StitchMatcher.match(shot(0, phase: 1), shot(120, phase: 2), ignoringRightColumns: 0)
                == .uncertain)
    }
}
