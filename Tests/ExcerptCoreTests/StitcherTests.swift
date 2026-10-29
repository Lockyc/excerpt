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

    /// Scrolls `page` under a 200-row frame by 120 rows, each frame passed through `dress`;
    /// returns the stitch and the last frame.
    func scrollDressed(_ page: PixelBuffer, _ dress: (PixelBuffer) -> PixelBuffer) -> (
        Stitcher, PixelBuffer
    ) {
        var stitcher = Stitcher(
            first: dress(ScrollFixtures.frame(page, offset: 0, viewport: 200)), scale: 1)
        var last = stitcher.image
        for offset in stride(from: 120, through: page.height - 200, by: 120) {
            last = dress(ScrollFixtures.frame(page, offset: offset, viewport: 200))
            #expect(stitcher.add(last) == .appended(rows: 120))
        }
        return (stitcher, last)
    }

    @Test func aFloatingElementAboveTheBottomShowsOnceFromTheLastFrame() {
        // A 30x40 block clear of the frame's right and bottom edges, over the page.
        let block = ScrollFixtures.bar(width: 30, height: 40, tone: 140)
        let (stitcher, last) = scrollDressed(ScrollFixtures.page(width: 90, height: 920)) {
            frame in
            ScrollFixtures.paint(width: 90, height: 200) { x, y in
                (50..<80).contains(x) && (150..<190).contains(y)
                    ? block[x: x - 50, y: y - 150] : frame[x: x, y: y]
            }
        }
        let page = ScrollFixtures.page(width: 90, height: 920)
        #expect(stitcher.image == ScrollFixtures.stack([ScrollFixtures.rows(page, 0..<720), last]))
    }

    @Test func aWallpaperFixedBehindThePageIsCopiedWithEachFramesRows() {
        let page = ScrollFixtures.page(width: 90, height: 920)
        let (stitcher, _) = scrollDressed(page, ScrollFixtures.wallpapered)
        let image = stitcher.image
        let paper = StitchMatcher.background(page)!
        // Which frame's wallpaper shows on a blank row depends on where the frames joined.
        #expect(StitchMatcher.flattened(image, toward: paper) == page)
        // The page's margin, wallpaper only, is copied in every frame's rows, never painted flat.
        // A quarter of its pixels are wallpaper: far more than none in each frame's rows.
        for rows in stride(from: 200, to: 900, by: 120).map({ $0..<($0 + 100) }) {
            let marked = rows.reduce(0) { count, y in
                count + (0..<4).filter { image[x: $0, y: y] != ScrollFixtures.paper }.count
            }
            #expect(marked > rows.count * 4 / 8)
        }
    }

    @Test func aFooterWithAFadeAboveItShowsOnceFromTheLastFrame() {
        // A 30-row footer under 24 rows that blend the page toward grey.
        let footer = ScrollFixtures.bar(width: 90, height: 30, tone: 140)
        let (stitcher, last) = scrollDressed(ScrollFixtures.page(width: 90, height: 920)) {
            frame in
            let barred = ScrollFixtures.overlay(frame, footer, atRow: 170)
            return ScrollFixtures.paint(width: 90, height: 200) { x, y in
                let c = barred[x: x, y: y]
                guard (146..<170).contains(y) else { return c }
                let t = Double(y - 145) / 25
                func blend(_ v: UInt8) -> UInt8 { UInt8(Double(v) * (1 - t) + 128 * t) }
                return RGBA(r: blend(c.r), g: blend(c.g), b: blend(c.b), a: 255)
            }
        }
        let page = ScrollFixtures.page(width: 90, height: 920)
        #expect(stitcher.image == ScrollFixtures.stack([ScrollFixtures.rows(page, 0..<720), last]))
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

    @Test func aBarPinningUnderTheHeaderShowsOnceInItsPlace() {
        // A 16-row bar in the page's flow at row 40 pins under the 20-row header once scrolled
        // there: the stitch is the first frame, the bar in its flow, then the page.
        let header = ScrollFixtures.bar(width: 90, height: 20, tone: 60)
        let nav = ScrollFixtures.bar(width: 90, height: 16, tone: 200)
        let page = ScrollFixtures.overlay(
            ScrollFixtures.page(width: 90, height: 1000), nav, atRow: 40)
        func at(_ offset: Int) -> PixelBuffer {
            ScrollFixtures.overlay(
                ScrollFixtures.frame(page, offset: offset, viewport: 200, header: header), nav,
                atRow: max(20, 40 - offset))
        }
        var stitcher = Stitcher(first: at(0), scale: 1)
        #expect(stitcher.add(at(120)) == .appended(rows: 120))
        #expect(stitcher.add(at(240)) == .appended(rows: 120))
        #expect(
            stitcher.image
                == ScrollFixtures.stack([at(0), ScrollFixtures.rows(page, 200..<440)]))
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

    /// `panel` (30 columns), the 90-column page, and a 20-column blank margin.
    func panelled(_ panel: PixelBuffer, page: PixelBuffer, offset: Int) -> PixelBuffer {
        let margin = ScrollFixtures.paint(width: 20, height: 200) { _, _ in ScrollFixtures.paper }
        return ScrollFixtures.beside(
            ScrollFixtures.beside(panel, ScrollFixtures.frame(page, offset: offset, viewport: 200)),
            margin)
    }

    @Test func aStickySidePanelShowsOnceAndTheBackgroundRunsOnUnderIt() {
        // The panel moves 40 rows on the first step while pinning, then stays put.
        let page = ScrollFixtures.page(width: 90, height: 1000)
        let panelPage = ScrollFixtures.page(width: 30, height: 400, seed: 2)
        let first = ScrollFixtures.frame(panelPage, offset: 0, viewport: 200)
        let pinned = ScrollFixtures.frame(panelPage, offset: 40, viewport: 200)
        var stitcher = Stitcher(first: panelled(first, page: page, offset: 0), scale: 1)
        for offset in Array(stride(from: 120, through: 800, by: 120)) + [800] {
            _ = stitcher.add(panelled(pinned, page: page, offset: offset))
        }
        let paper = { (w: Int, h: Int) in
            ScrollFixtures.paint(width: w, height: h) { _, _ in ScrollFixtures.paper }
        }
        let expected = ScrollFixtures.beside(
            ScrollFixtures.beside(ScrollFixtures.stack([first, paper(30, 800)]), page),
            paper(20, 1000))
        #expect(stitcher.image == expected)
    }

    @Test func theScrollBarStripIsCopiedNotFilled() {
        // Page content reaches the right edge, inside the ignored scroll-bar strip.
        let page = ScrollFixtures.paint(width: 90, height: 1000) { x, y in
            ScrollFixtures.mix(5, UInt64(y), UInt64(x / 2)) % 4 == 0
                ? ScrollFixtures.ink : ScrollFixtures.paper
        }
        let (stitcher, _) = scroll(page, viewport: 200, step: 120)
        #expect(stitcher.image == page)
    }

    @Test func fillIsTheCommonestColourWithTiesBrokenByValue() {
        // Sampled every fourth row (0, 4, 8). Column 0: ink, ink, paper → ink. Column 1: ink,
        // paper, paper → paper. Column 2: ink, paper and a tint, a three-way tie won by the
        // smallest packed value: ink (RGBA 30,30,40,255 is 0xFF28_1E1E little-endian).
        let tint = RGBA(r: 200, g: 200, b: 200, a: 255)
        let frame = ScrollFixtures.paint(width: 4, height: 12) { x, y in
            switch (x, y / 4) {
            case (0, 0), (0, 1), (1, 0), (2, 0): ScrollFixtures.ink
            case (2, 2): tint
            default: ScrollFixtures.paper
            }
        }
        // Against an all-tint previous frame no column moved with the page, so all three fill.
        let previous = ScrollFixtures.paint(width: 4, height: 12) { _, _ in tint }
        let filled = PixelBuffer(
            width: 4, height: 2,
            bytes: Stitcher.content(
                frame, rows: 0..<2, band: 3..<4, matched: 4, previous: previous, offset: 1,
                overlap: 0..<8))
        #expect(filled[x: 0, y: 1] == ScrollFixtures.ink)
        #expect(filled[x: 1, y: 1] == ScrollFixtures.paper)
        #expect(filled[x: 2, y: 1] == ScrollFixtures.ink)
    }
}
