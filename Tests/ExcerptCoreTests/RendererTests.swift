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
