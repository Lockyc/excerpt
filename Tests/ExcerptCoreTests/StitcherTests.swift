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
}
