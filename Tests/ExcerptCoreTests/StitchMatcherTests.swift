import ExcerptTestSupport
import PropertyBased
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

    /// Two frames of a generated scene `move` rows apart, the first at page row `offset`, the
    /// hover block at row `hoverRow` and then `hoverShift` rows lower (the next message under the
    /// pointer); `strip` leaves out the scroll-bar strip.
    func generatedMatch(
        _ scene: ScrollFixtures.Scene, offset: Int, move: Int, hoverRow: Int, hoverShift: Int,
        strip: Bool
    ) -> FrameMatch {
        let page = scene.page(height: offset + move + scene.viewport)
        let width = scene.width + scene.panel
        return StitchMatcher.match(
            scene.frame(page, offset: offset, hoverRow: hoverRow),
            scene.frame(page, offset: offset + move, hoverRow: hoverRow + hoverShift),
            ignoringRightColumns: strip
                ? StitchMatcher.ignoredRightColumns(width: width, scale: 1)
                : 0,
            chrome: scene.chrome)
    }

    /// `alias` is a whole number of repeated-block periods from the true `move`, and once the
    /// rows a move may leave out are left out (the sticky header and any blank rows that line up
    /// under it, the sticky footer and an overlay over the page above it) no more page rows than
    /// the contradictions a move tolerates differ between the frames there: the known limit
    /// `knownIssueARepeatedBlockWithItsTellingRowsHiddenAliases`.
    func blockAliasIsKnownLimit(
        _ scene: ScrollFixtures.Scene, offset: Int, move: Int, match: FrameMatch
    ) -> Bool {
        guard scene.block > 0, case .moved(let alias, let header, let footer, _) = match,
            alias > 0, (move - alias) % ScrollFixtures.Scene.repeatPeriod == 0,
            header <= scene.header + 6,
            footer
                <= scene.footer
                + Int(Double(scene.viewport) * StitchMatcher.maximumOverlayShare) + 6
        else { return false }
        let page = scene.page(height: offset + move + scene.viewport)
        func row(_ y: Int) -> PixelBuffer { ScrollFixtures.rows(page, y..<(y + 1)) }
        func blank(_ row: PixelBuffer) -> Bool { row.bytes.allSatisfy { $0 == 255 } }
        // A blank row is no evidence either way: only two rows of text can contradict.
        let differing = (header..<max(header, scene.viewport - alias - footer)).count {
            let a = row(offset + alias + $0)
            let b = row(offset + move + $0)
            return a != b && !blank(a) && !blank(b)
        }
        return differing <= StitchMatcher.maximumContradictions
    }

    /// The matcher must never fabricate a seam: whatever bars, toolbar band, wallpaper, hover
    /// block, side panel or repeated block a generated scene shows, a move is the true one or the
    /// match is uncertain. A move is within a frame, or a period of the repeated block further:
    /// past any overlap, where only an alias one period short could match.
    @Test func anyMatchIsTheTrueOffsetOrUncertain() async {
        await propertyCheck(
            count: propertyRuns(gate: 60),
            input: ScrollSceneGen.scene, Gen.int(in: 0...400), Gen.int(in: 1...100), Gen.bool,
            Gen.int(in: 0...280), Gen.int(in: -40...40), Gen.bool
        ) { scene, offset, moveShare, jump, hoverRow, hoverShift, strip in
            let move =
                max(1, scene.viewport * moveShare / 100)
                + (jump ? ScrollFixtures.Scene.repeatPeriod : 0)
            let match = generatedMatch(
                scene, offset: offset, move: move, hoverRow: hoverRow, hoverShift: hoverShift,
                strip: strip)
            switch match {
            case .uncertain: break
            case .moved(let found, _, _, _) where found == move: break
            case .moved
            where blockAliasIsKnownLimit(scene, offset: offset, move: move, match: match):
                break
            default:
                let input =
                    "\(scene), offset \(offset), move \(move), hover \(hoverRow)+\(hoverShift), "
                    + "strip \(strip)"
                Issue.record("\(input): \(match)")
            }
        }
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

    @Test func aFaintWallpaperFixedBehindThePageDoesNotHideTheMove() {
        let match = StitchMatcher.match(
            ScrollFixtures.wallpapered(frame(0)), ScrollFixtures.wallpapered(frame(120)),
            ignoringRightColumns: 0)
        #expect(offset(match) == 120)
    }

    @Test func aColumnComparedTowardTheBackgroundMovesAsItsFlattenedColumnDoes() {
        let previous = ScrollFixtures.wallpapered(frame(0))
        let next = ScrollFixtures.wallpapered(frame(120))
        let background = StitchMatcher.background(previous)!
        let flatPrevious = StitchMatcher.flattened(previous, toward: background)
        let flatNext = StitchMatcher.flattened(next, toward: background)
        var moved = 0
        for offset in [0, 60, 120] {
            for x in 0..<90 {
                let rows = 0..<(200 - offset)
                let flat = StitchMatcher.columnMoved(
                    x, flatPrevious, flatNext, offset: offset, rows: rows)
                #expect(
                    StitchMatcher.columnMoved(
                        x, previous, next, offset: offset, rows: rows,
                        flattenedToward: background) == flat)
                if flat { moved += 1 }
            }
        }
        // Both answers occur, or the comparison proves nothing.
        #expect(moved > 0 && moved < 270)
    }

    /// `frame` with the footer's shadow cast up over the 3 rows above it, blending them toward
    /// grey.
    func shadowed(_ frame: PixelBuffer) -> PixelBuffer {
        ScrollFixtures.paint(width: 90, height: 200) { x, y in
            let c = frame[x: x, y: y]
            guard (181..<184).contains(y) else { return c }
            let t = Double(y - 180) / 4
            func blend(_ v: UInt8) -> UInt8 { UInt8(Double(v) * (1 - t) + 128 * t) }
            return RGBA(r: blend(c.r), g: blend(c.g), b: blend(c.b), a: 255)
        }
    }

    @Test func aFootersShadowOverThePageJoinsTheFooter() {
        // Text under the shadow differs across the width once it moves: three contradictions.
        let match = StitchMatcher.match(
            shadowed(frame(0, footer: footer)), shadowed(frame(120, footer: footer)),
            ignoringRightColumns: 0)
        guard case .moved(let offset, _, let bottom, _) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(offset == 120)
        #expect(bottom >= 19 && bottom < 25)
    }

    /// `frame` beside a scroll bar inside the region: a gap, a 6-column track with its thumb
    /// from row `thumb`, then a 16-column panel that doesn't scroll.
    func besideScrollBar(_ frame: PixelBuffer, thumb: Int) -> PixelBuffer {
        let panel = ScrollFixtures.bar(width: 16, height: 200, tone: 30)
        return ScrollFixtures.paint(width: 116, height: 200) { x, y in
            switch x {
            case ..<90: frame[x: x, y: y]
            case 90..<94: ScrollFixtures.paper
            case 94..<100:
                (thumb..<(thumb + 60)).contains(y)
                    ? RGBA(r: 90, g: 90, b: 90, a: 255) : RGBA(r: 45, g: 45, b: 45, a: 255)
            default: panel[x: x - 100, y: y]
            }
        }
    }

    @Test func aScrollThumbInsideTheRegionIsLeftOut() {
        // The thumb moves down as the page moves up, across most of the overlap's rows.
        let match = StitchMatcher.match(
            besideScrollBar(frame(0), thumb: 0), besideScrollBar(frame(120), thumb: 20),
            ignoringRightColumns: 16)
        guard case .moved(let offset, _, _, let columns) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(offset == 120)
        #expect(columns.upperBound <= 90)
    }

    /// The page with a 16-row nav bar in its flow at row 40, scrolled to `offset` under the
    /// header: the bar pins under the header once the page scrolls it there.
    func navFrame(_ offset: Int) -> PixelBuffer {
        let nav = ScrollFixtures.bar(width: 90, height: 16, tone: 200)
        return ScrollFixtures.overlay(
            ScrollFixtures.frame(
                ScrollFixtures.overlay(page, nav, atRow: 40), offset: offset, viewport: 200,
                header: header),
            nav, atRow: max(24, 40 - offset))
    }

    @Test func aBarPinningUnderTheHeaderJoinsIt() {
        let match = StitchMatcher.match(navFrame(0), navFrame(120), ignoringRightColumns: 0)
        guard case .moved(let offset, let top, _, _) = match else {
            Issue.record("expected a move, got \(match)")
            return
        }
        #expect(offset == 120)
        #expect(top >= 40 && top < 46)  // header and bar, plus any blank rows that coincide
    }

    /// `buffer` with `rows` re-rasterised: every fifth pixel's red off by `levels`. Over half the
    /// overlap of a 120-row move, the rows' signatures alone can't convince.
    func dithered(_ buffer: PixelBuffer, rows: Range<Int>, levels: UInt8 = 1) -> PixelBuffer {
        var out = buffer
        for y in rows {
            for x in stride(from: y % 5, to: buffer.width, by: 5) {
                let i = (y * buffer.width + x) * 4
                out.bytes[i] = out.bytes[i] > 127 ? out.bytes[i] - levels : out.bytes[i] + levels
            }
        }
        return out
    }

    @Test func aMoveRedrawnOneLevelOffStillMatches() {
        #expect(
            offset(
                StitchMatcher.match(
                    frame(0), dithered(frame(120), rows: 40..<160), ignoringRightColumns: 0))
                == 120)
    }

    @Test func aMoveRedrawnTwoLevelsOffIsUncertain() {
        // The top half of the overlap: redrawn rows at its bottom read as a static overlay.
        #expect(
            StitchMatcher.match(
                frame(0), dithered(frame(120), rows: 0..<40, levels: 2),
                ignoringRightColumns: 0)
                == .uncertain)
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

    /// `frame(offset)` with a hover toolbar (the same block each time, 16 rows tall and `width`
    /// wide) on the page at `pageRow`: a chat shows it on whichever message is under the pointer.
    func hovered(_ offset: Int, pageRow: Int, width: Int) -> PixelBuffer {
        ScrollFixtures.animated(
            frame(offset), x: 20, y: pageRow - offset, width: width, height: 16, phase: 7)
    }

    @Test func aHoverToolbarThatMovesToTheNextMessageDoesNotHaltTheMove() {
        // Wider than a quarter of the frame, it leaves the message it was on and appears on the
        // next one, both near the top of the overlap, clear of anything the footer could take.
        let a = hovered(0, pageRow: 125, width: 36)
        let b = hovered(120, pageRow: 145, width: 36)
        #expect(offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 120)
    }

    @Test func aHoverOverlayWiderThanHalfTheFrameIsUncertain() {
        let a = hovered(0, pageRow: 125, width: 60)
        let b = hovered(120, pageRow: 145, width: 60)
        #expect(StitchMatcher.match(a, b, ignoringRightColumns: 0) == .uncertain)
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

    @Test func cardsWhoseEveryLineRepeatsMatchOnTheirRunOfLines() {
        // Each name heads several cards and each slot recurs under every name: no single row is
        // unique in a frame, but the run from a card's name to its slot is.
        let cards = ScrollFixtures.cards(width: 90, count: 40)
        let a = ScrollFixtures.frame(cards, offset: 0, viewport: 680)
        let b = ScrollFixtures.frame(cards, offset: 408, viewport: 680)
        let rows = RowSignatures(a, columns: 0..<90)
        let unique = StitchMatcher.uniqueRows(rows, in: 0..<680)
        #expect(!unique.indices.contains { unique[$0] && !rows.uniform[$0] })
        #expect(offset(StitchMatcher.match(a, b, ignoringRightColumns: 0)) == 408)
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

    @Test func knownIssueRepeatedContentUnderAWindowsToolbarCanAlias() {
        // The long repeated-block alias above, in a window with a translucent toolbar over its
        // top quarter: the rows that tell the alias apart sit under the toolbar, whose rows are
        // left out of the move.
        let long = repeating(phase: 60, block: 140)
        let window = ScrollChrome(fixedTop: 2, fixedBottom: 0, fillsScrollBar: false)
        withKnownIssue(
            "a translucent toolbar can't yet be told from aliased repeated content under the toolbar"
        ) {
            #expect(
                StitchMatcher.match(
                    ScrollFixtures.tinted(
                        ScrollFixtures.frame(long, offset: 0, viewport: 200), rows: 50),
                    ScrollFixtures.tinted(
                        ScrollFixtures.frame(long, offset: 300, viewport: 200), rows: 50),
                    ignoringRightColumns: 0, chrome: window) == .uncertain)
        }
    }

    @Test func knownIssueARepeatedBlockWithItsTellingRowsHiddenAliases() {
        // Found by `anyMatchIsTheTrueOffsetOrUncertain`. A block repeats every 250 rows and the
        // page jumps more than a frame, so only the frame one period short overlaps. The rows
        // that tell it apart from the block sit where a move may leave rows out.
        withKnownIssue("a repeated block aliases when the rows that tell it apart are hidden") {
            // Jumping 389 past a 90-row block: of the 112-row overlap the sticky header covers
            // 13, 2 rows of text differ (within the contradictions a move tolerates as
            // animation), then 6 blank rows and the block's 88 match.
            let under = ScrollFixtures.Scene(
                seed: 1, block: 90, width: 64, viewport: 251, header: 13)
            let page = under.page(height: 640)
            #expect(
                StitchMatcher.match(
                    under.frame(page, offset: 0), under.frame(page, offset: 389),
                    ignoringRightColumns: 0) == .uncertain)
            // Jumping 304 past a 40-row block under a 39-row header: the differing rows at the
            // overlap's end read as an overlay over the page above the footer.
            let over = ScrollFixtures.Scene(
                seed: 1, block: 40, width: 64, viewport: 156, header: 39)
            let long = over.page(height: 820)
            #expect(
                StitchMatcher.match(
                    over.frame(long, offset: 359), over.frame(long, offset: 663),
                    ignoringRightColumns: 0) == .uncertain)
        }
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

    @Test func headOverlayRowsFindTheLowestDifferingPair() {
        // 40 rows, all unique; the overlap starts at row 5, `a` 10 rows lower than `b`.
        let hashes = (0..<40).map { UInt64($0 + 1) }
        let a = RowSignatures(hashes: hashes, uniform: Array(repeating: false, count: 40))
        let unique = Array(repeating: true, count: 40)
        func shifted(differing: Set<Int>) -> RowSignatures {
            // `b`'s row n is `a`'s row n + 10, except the overlap's pairs in `differing`.
            let b = (0..<40).map { n -> UInt64 in
                differing.contains(n - 5) ? 1000 + UInt64(n) : n + 10 < 40 ? hashes[n + 10] : 0
            }
            return RowSignatures(hashes: b, uniform: Array(repeating: false, count: 40))
        }
        func head(_ b: RowSignatures) -> Int {
            StitchMatcher.headOverlayRows(
                a, b, start: 5, offset: 10, count: 25, limit: 10, uniqueA: unique, uniqueB: unique)
        }
        #expect(head(shifted(differing: [0, 3, 7])) == 8)
        #expect(head(shifted(differing: [])) == 0)
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
