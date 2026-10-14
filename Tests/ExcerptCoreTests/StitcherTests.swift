import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct StitcherTests {
    /// Scrolls `page` under a `viewport`-row frame by `step` rows until the end, adding each
    /// frame; returns the stitcher and the offsets it saw.
    func scroll(
        _ page: PixelBuffer, viewport: Int, step: Int, header: PixelBuffer? = nil,
        footer: PixelBuffer? = nil, maximumHeight: Int = Stitcher.defaultMaximumHeight
    ) -> (Stitcher, [StitchStep]) {
        var stitcher = Stitcher(
            first: ScrollFixtures.frame(
                page, offset: 0, viewport: viewport, header: header, footer: footer), scale: 1,
            maximumHeight: maximumHeight)
        var steps: [StitchStep] = []
        var offset = 0
        while offset < page.height - viewport {
            offset = min(offset + step, page.height - viewport)
            steps.append(
                stitcher.add(
                    ScrollFixtures.frame(
                        page, offset: offset, viewport: viewport, header: header, footer: footer)))
        }
        return (stitcher, steps)
    }

    @Test func aLongPageStitchesToThePage() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let (stitcher, steps) = scroll(page, viewport: 200, step: 120)
        #expect(steps.allSatisfy { if case .appended = $0 { true } else { false } })
        #expect(stitcher.image == page)
    }

    @Test func stickyHeaderComesFromTheFirstFrameAndFooterFromTheLast() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let header = ScrollFixtures.bar(width: 90, height: 24, tone: 60)
        let footer = ScrollFixtures.bar(width: 90, height: 16, tone: 140)
        let (stitcher, _) = scroll(page, viewport: 200, step: 120, header: header, footer: footer)
        let expected = ScrollFixtures.stack([
            header, ScrollFixtures.rows(page, 24..<(1000 - 16)), footer,
        ])
        #expect(stitcher.image == expected)
    }

    @Test func aLongFormWithRepeatingFieldsStitches() {
        let form = ScrollFixtures.form(width: 90, height: 1000)
        let (stitcher, _) = scroll(form, viewport: 200, step: 120)
        #expect(stitcher.image == form)
    }

    @Test func aSmallAnimatedElementDoesNotStopTheStitch() {
        // A spinner fixed in the viewport (position: fixed), changing every frame.
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(
            first: ScrollFixtures.animated(
                ScrollFixtures.frame(page, offset: 0, viewport: 200), x: 60, y: 90, width: 12,
                height: 12, phase: 0), scale: 1)
        for (index, offset) in [120, 240, 360].enumerated() {
            let frame = ScrollFixtures.animated(
                ScrollFixtures.frame(page, offset: offset, viewport: 200), x: 60, y: 90,
                width: 12, height: 12, phase: index + 1)
            #expect(stitcher.add(frame) == .appended(rows: 120))
        }
        #expect(stitcher.height == 560)
        // Away from the spinner's columns the stitch is the page.
        #expect(
            ScrollFixtures.columns(stitcher.image, 0..<60)
                == ScrollFixtures.columns(ScrollFixtures.rows(page, 0..<560), 0..<60))
    }

    @Test func anUncertainFrameLeavesTheStitchAsItWas() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(
            first: ScrollFixtures.frame(page, offset: 0, viewport: 200), scale: 1)
        #expect(
            stitcher.add(ScrollFixtures.frame(page, offset: 120, viewport: 200))
                == .appended(rows: 120))
        let video = ScrollFixtures.animated(
            ScrollFixtures.frame(page, offset: 240, viewport: 200), x: 0, y: 0, width: 90,
            height: 200, phase: 3)
        #expect(stitcher.add(video) == .uncertain)
        #expect(stitcher.image == ScrollFixtures.rows(page, 0..<320))
        // The next frame is matched against the last good one, not the video.
        #expect(
            stitcher.add(ScrollFixtures.frame(page, offset: 240, viewport: 200))
                == .appended(rows: 120))
    }

    @Test func aMoveOutsideTheExpectedTravelLeavesTheStitchAsItWas() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(
            first: ScrollFixtures.frame(page, offset: 0, viewport: 200), scale: 1)
        let frame = ScrollFixtures.frame(page, offset: 120, viewport: 200)
        #expect(stitcher.add(frame, travel: 30...90) == .unexpectedTravel(offset: 120))
        #expect(stitcher.height == 200)
        #expect(stitcher.add(frame, travel: 30...180) == .appended(rows: 120))
    }

    @Test func noMovementChangesNothing() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(
            first: ScrollFixtures.frame(page, offset: 0, viewport: 200), scale: 1)
        #expect(stitcher.add(ScrollFixtures.frame(page, offset: 0, viewport: 200)) == .noMovement)
        #expect(stitcher.height == 200)
    }

    @Test func stopsAtTheMaximumHeightKeepingRowsUpToIt() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let (stitcher, steps) = scroll(page, viewport: 200, step: 120, maximumHeight: 500)
        #expect(steps.prefix(3) == [.appended(rows: 120), .appended(rows: 120), .reachedLimit])
        #expect(steps.dropFirst(3).allSatisfy { $0 == .reachedLimit })
        #expect(stitcher.height == 500)
        #expect(stitcher.image == ScrollFixtures.rows(page, 0..<500))
    }

    @Test func aMaximumBelowTheFirstFrameKeepsTheFirstFrame() {
        let page = ScrollFixtures.page(width: 90, height: 400)
        var stitcher = Stitcher(
            first: ScrollFixtures.frame(page, offset: 0, viewport: 200), scale: 1,
            maximumHeight: 50)
        #expect(stitcher.maximumHeight == 200)
        #expect(
            stitcher.add(ScrollFixtures.frame(page, offset: 120, viewport: 200)) == .reachedLimit)
        #expect(stitcher.height == 200)
    }

    @Test func theBottomIsTheNewestRows() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let (stitcher, _) = scroll(page, viewport: 200, step: 120)
        #expect(stitcher.bottom(rows: 100) == ScrollFixtures.rows(page, 900..<1000))
        #expect(stitcher.bottom(rows: 5000) == page)
    }

    /// A solid band: its identical rows say nothing to the matcher, so a footer that changes
    /// height doesn't count against the offset.
    func solid(_ height: Int) -> PixelBuffer {
        ScrollFixtures.paint(width: 90, height: height) { _, _ in
            RGBA(r: 20, g: 90, b: 160, a: 255)
        }
    }

    /// The viewport at `offset` over `page` with a solid footer of `footer` rows (none for 0).
    func footerFrame(_ page: PixelBuffer, offset: Int, footer: Int) -> PixelBuffer {
        ScrollFixtures.frame(
            page, offset: offset, viewport: 200, header: nil,
            footer: footer == 0 ? nil : solid(footer))
    }

    @Test func aFooterThatShrinksLeavesNoStaleBar() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(first: footerFrame(page, offset: 0, footer: 30), scale: 1)
        _ = stitcher.add(footerFrame(page, offset: 120, footer: 30))
        _ = stitcher.add(footerFrame(page, offset: 240, footer: 10))
        let expected = ScrollFixtures.stack([
            ScrollFixtures.rows(page, 0..<(240 + 200 - 10)),
            solid(10),
        ])
        #expect(stitcher.image == expected)
    }

    @Test func aFooterThatVanishesRevealsTheRowsItCovered() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(first: footerFrame(page, offset: 0, footer: 30), scale: 1)
        _ = stitcher.add(footerFrame(page, offset: 120, footer: 30))
        _ = stitcher.add(footerFrame(page, offset: 240, footer: 0))
        #expect(stitcher.image == ScrollFixtures.rows(page, 0..<440))
    }

    @Test func aFooterThatGrowsReplacesTheOldOne() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(first: footerFrame(page, offset: 0, footer: 10), scale: 1)
        _ = stitcher.add(footerFrame(page, offset: 120, footer: 10))
        _ = stitcher.add(footerFrame(page, offset: 240, footer: 30))
        let expected = ScrollFixtures.stack([
            ScrollFixtures.rows(page, 0..<(240 + 200 - 30)),
            solid(30),
        ])
        #expect(stitcher.image == expected)
    }

    @Test func truncatingAtTheCapOmitsTheFooterAndStaysContiguous() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let footer = ScrollFixtures.bar(width: 90, height: 16, tone: 140)
        let (stitcher, steps) = scroll(
            page, viewport: 200, step: 120, footer: footer, maximumHeight: 500)
        #expect(steps.last == .reachedLimit)
        #expect(stitcher.height == 500)
        #expect(stitcher.image == ScrollFixtures.rows(page, 0..<500))
    }

    @Test func reachingTheCapExactlyReportsTheLimitAtThatAppend() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let (stitcher, steps) = scroll(page, viewport: 200, step: 120, maximumHeight: 440)
        #expect(steps.prefix(2) == [.appended(rows: 120), .reachedLimit])
        #expect(steps.dropFirst(2).allSatisfy { $0 == .reachedLimit })
        #expect(stitcher.image == ScrollFixtures.rows(page, 0..<440))
    }

    @Test func theBottomIsAtLeastOneRow() {
        let page = ScrollFixtures.page(width: 90, height: 400)
        let stitcher = Stitcher(
            first: ScrollFixtures.frame(page, offset: 0, viewport: 200), scale: 1)
        #expect(stitcher.bottom(rows: 0) == ScrollFixtures.rows(page, 199..<200))
        #expect(stitcher.bottom(rows: -3) == ScrollFixtures.rows(page, 199..<200))
    }

    @Test func aMoveThatSkipsRowsTheFooterHidIsUncertain() {
        let page = ScrollFixtures.page(width: 90, height: 1000)
        var stitcher = Stitcher(first: footerFrame(page, offset: 0, footer: 30), scale: 1)
        _ = stitcher.add(footerFrame(page, offset: 120, footer: 30))
        let before = stitcher.image
        // 175 rows on with the footer gone: the 30 rows it hid start 5 rows past this frame.
        #expect(stitcher.add(footerFrame(page, offset: 295, footer: 0)) == .uncertain)
        #expect(stitcher.image == before)
    }

    @Test func aGrownFooterCoveringTheNewRowsStillCountsAsMovement() {
        // The page is blank in the footer's colour just above where the footer grows, so the
        // matcher sees a 30-row footer after the 10-row one.
        let plain = ScrollFixtures.page(width: 90, height: 1000)
        let page = ScrollFixtures.stack([
            ScrollFixtures.rows(plain, 0..<290), solid(20), ScrollFixtures.rows(plain, 310..<1000),
        ])
        var stitcher = Stitcher(first: footerFrame(page, offset: 0, footer: 10), scale: 1)
        _ = stitcher.add(footerFrame(page, offset: 120, footer: 10))
        let before = stitcher.image
        #expect(stitcher.add(footerFrame(page, offset: 130, footer: 30)) == .appended(rows: 0))
        #expect(stitcher.image == before)
    }

    @Test func aFooterThatUnsticksUnderTheHeaderIsUncertain() {
        // A 30-row footer that sits in the page's flow at row 240 sticks to the viewport's
        // bottom until the page scrolls it into place; at 230 it shows unstuck, partly under a
        // 20-row header. The only overlap left is inside the old tail footer and the header.
        let header = ScrollFixtures.bar(width: 90, height: 20, tone: 60)
        let footer = ScrollFixtures.bar(width: 90, height: 30, tone: 140)
        let page = ScrollFixtures.overlay(
            ScrollFixtures.page(width: 90, height: 1000), footer, atRow: 240)
        func stuck(_ offset: Int) -> PixelBuffer {
            ScrollFixtures.frame(
                page, offset: offset, viewport: 200, header: header, footer: footer)
        }
        var stitcher = Stitcher(first: stuck(0), scale: 1)
        #expect(stitcher.add(stuck(60)) == .appended(rows: 60))
        let before = stitcher.image
        let unstuck = ScrollFixtures.frame(page, offset: 230, viewport: 200, header: header)
        guard
            case .moved(160, 20, 0, _) = StitchMatcher.match(
                stuck(60), unstuck, ignoringRightColumns: 0)
        else {
            Issue.record("expected the unstuck footer to read as a 160-row move")
            return
        }
        #expect(stitcher.add(unstuck) == .uncertain)
        #expect(stitcher.image == before)
    }
}
