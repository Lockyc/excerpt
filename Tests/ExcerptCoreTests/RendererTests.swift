import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct RendererTests {
    @Test func labelTextIsInPointsWithGrouping() {
        #expect(SeamLabel.text(removedPixels: 2480, scale: 2) == "⋯ 1,240 px hidden")
        #expect(SeamLabel.text(removedPixels: 7, scale: 1) == "⋯ 7 px hidden")
    }

    @Test func noCutsReturnsTheOriginal() {
        let image = Fixtures.sheet(width: 120, height: 80)
        let result = Renderer.render(image, edits: EditDocument(scale: 1))
        #expect(PixelBuffer(result.image) == PixelBuffer(image))
    }

    @Test func bothAxesShrinkTheImage() {
        let image = Fixtures.sheet(width: 600, height: 800)
        let edits = EditDocument(
            scale: 2,
            cuts: [
                Cut(axis: .horizontal, lower: 121, upper: 601),
                Cut(axis: .vertical, lower: 181, upper: 421),
            ])
        let result = Renderer.render(image, edits: edits)
        let gap = SeamStyle.standard.gapPixels(scale: 2)
        #expect(result.image.height == 800 - 480 + gap)
        #expect(result.image.width == 600 - 240 + gap)
        #expect(result.rows.gaps.count == 1)
        #expect(result.columns.gaps.count == 1)
    }

    @Test func wholeExtentCutIsIgnored() {
        let image = Fixtures.sheet(width: 100, height: 100)
        let edits = EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 0, upper: 100)])
        #expect(Renderer.render(image, edits: edits).image.height == 100)
    }

    @Test func bothAxesGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 800)
        let edits = EditDocument(
            scale: 2,
            cuts: [
                Cut(axis: .horizontal, lower: 121, upper: 601),
                Cut(axis: .vertical, lower: 181, upper: 421),
            ])
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-both-axes")
    }
}

@Suite struct SeamLabelPlacementTests {
    @Test func pillStaysInsideANarrowCanvas() {
        let pill = SeamLabel.pillSize(text: SeamLabel.text(removedPixels: 240, scale: 2), scale: 2)
        let canvas = 300.0
        for desired in [0.0, 150, 300] {
            let c = SeamLabel.clampedCentre(
                desired: desired, length: Double(pill.width), segment: 0..<100, canvas: canvas,
                margin: 8)
            #expect(c - Double(pill.width) / 2 >= 0)
            #expect(c + Double(pill.width) / 2 <= canvas)
        }
    }

    @Test func pillStaysInsideItsSegmentWhenItFits() {
        let c = SeamLabel.clampedCentre(
            desired: 90, length: 100, segment: 0..<181, canvas: 400, margin: 8)
        #expect(c - 50 >= 8 && c + 50 <= 181 - 8)
    }

    @Test func labelsCentreOnTheLargestKeptSegmentOfTheOtherAxis() {
        let map = AxisMap(extent: 600, bands: [200..<300], gap: 20)
        #expect(Renderer.largestSegment(of: map) == 220.0..<520.0)
        #expect(
            Renderer.largestSegment(of: AxisMap(extent: 100, bands: [], gap: 20)) == 0.0..<100.0)
    }
}
