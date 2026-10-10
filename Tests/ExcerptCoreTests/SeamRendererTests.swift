import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct SeamRendererTests {
    let style = SeamStyle.standard

    @Test func noBandsReturnsTheImageUnchanged() {
        let image = Fixtures.rowStripes(width: 40, height: 100)
        let (out, map) = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [], style: style, scale: 1)
        #expect(PixelBuffer(out) == PixelBuffer(image))
        #expect(map.renderedLength == 100)
    }

    @Test func horizontalBandShortensAndKeepsRowsExactly() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let (out, map) = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [100..<300], style: style, scale: 1)
        #expect(out.width == 40)
        #expect(out.height == 400 - 200 + style.gapPixels(scale: 1))
        let buffer = PixelBuffer(out)
        // The tear reaches `amplitude` into the content and its shadow a few pixels further.
        let margin = Int(style.amplitudePixels(scale: 1)) + 6
        for y in 0..<(100 - margin) { #expect(buffer[x: 20, y: y] == Fixtures.rowColor(y)) }
        let after = map.gaps[0].destination.upperBound
        for y in (after + margin)..<out.height {
            #expect(buffer[x: 20, y: y] == Fixtures.rowColor(y - after + 300))
        }
        let mid = (map.gaps[0].destination.lowerBound + map.gaps[0].destination.upperBound) / 2
        #expect(buffer[x: 20, y: mid] == style.gapColor)
    }

    @Test func verticalBandNarrowsAndKeepsColumnsExactly() {
        let image = Fixtures.columnStripes(width: 400, height: 30)
        let (out, map) = SeamRenderer.removeBands(
            image, axis: .vertical, bands: [50..<150], style: style, scale: 2)
        #expect(out.height == 30)
        #expect(out.width == 400 - 100 + style.gapPixels(scale: 2))
        let buffer = PixelBuffer(out)
        #expect(buffer[x: 10, y: 15] == Fixtures.rowColor(10))
        let after = map.gaps[0].destination.upperBound
        #expect(buffer[x: after + 20, y: 15] == Fixtures.rowColor(170))
    }

    @Test func edgeBandRendersWithoutCrashing() {
        let image = Fixtures.rowStripes(width: 40, height: 200)
        let (out, _) = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [0..<50], style: style, scale: 1)
        #expect(out.height == 150 + style.gapPixels(scale: 1))
        #expect(PixelBuffer(out)[x: 20, y: style.gapPixels(scale: 1) / 2] == style.gapColor)
    }

    @Test func identicalInputsRenderIdenticalPixels() {
        let image = Fixtures.sheet(width: 300, height: 400)
        let a = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [60..<300], style: style, scale: 2
        ).image
        let b = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [60..<300], style: style, scale: 2
        ).image
        #expect(PixelBuffer(a) == PixelBuffer(b))
    }

    @Test func horizontalSeamGolden() throws {
        let image = Fixtures.sheet(width: 360, height: 400)
        let out = SeamRenderer.removeBands(
            image, axis: .horizontal, bands: [81..<321], style: style, scale: 2
        ).image
        try Golden.check(out, named: "seam-horizontal")
    }
}
