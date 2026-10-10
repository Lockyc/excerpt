import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct BlurTests {
    /// Mid-grey with a darker stripe every 7 rows, so averages sit away from 0 and 255 and noise
    /// shows.
    static func grey(width: Int, height: Int) -> CGImage {
        Fixtures.paint(width: width, height: height) { _, y in
            y % 7 == 0
                ? RGBA(r: 60, g: 60, b: 60, a: 255) : RGBA(r: 128, g: 128, b: 128, a: 255)
        }
    }

    @Test func blocksAreAtLeastTwelvePointsAndSplitEvenly() {
        #expect(BlurRenderer.boundaries(length: 100, block: 24) == [0, 25, 50, 75, 100])
        #expect(BlurRenderer.boundaries(length: 30, block: 24) == [0, 30])
        #expect(BlurRenderer.boundaries(length: 10, block: 24) == [0, 10])
    }

    @Test func everyBlockIsOneColourAndOutsideIsUntouched() {
        let image = Self.grey(width: 120, height: 120)
        let out = PixelBuffer(
            BlurRenderer.apply(
                [CGRect(x: 10, y: 10, width: 48, height: 48)], to: image, scale: 2))
        let original = PixelBuffer(image)
        // Scale 2 → 24px blocks: 10..<34 and 34..<58 on each axis.
        for y in 10..<34 {
            for x in 10..<34 { #expect(out[x: x, y: y] == out[x: 10, y: 10]) }
        }
        #expect(out[x: 34, y: 10] != out[x: 10, y: 10])
        for (x, y) in [(9, 9), (58, 58), (100, 30), (30, 100)] {
            #expect(out[x: x, y: y] == original[x: x, y: y])
        }
    }

    @Test func noiseMovesBlocksOffTheirAverage() {
        // Uniform grey: every block averages 128, so only noise can tell them apart.
        let image = Fixtures.paint(width: 240, height: 24) { _, _ in
            RGBA(r: 128, g: 128, b: 128, a: 255)
        }
        let out = PixelBuffer(
            BlurRenderer.apply([CGRect(x: 0, y: 0, width: 240, height: 24)], to: image, scale: 2))
        let colours = Set((0..<10).map { out[x: $0 * 24, y: 0].r })
        #expect(colours.count > 1)
        for c in colours { #expect(abs(Int(c) - 128) <= BlurRenderer.noiseAmplitude) }
    }

    @Test func identicalEditsGiveIdenticalPixels() {
        let image = Fixtures.sheet(width: 200, height: 200)
        let rects = [CGRect(x: 20, y: 30, width: 100, height: 60)]
        let a = BlurRenderer.apply(rects, to: image, scale: 2)
        let b = BlurRenderer.apply(rects, to: image, scale: 2)
        #expect(PixelBuffer(a) == PixelBuffer(b))
    }

    @Test func coversTheWholeImageAndClampsAtTheEdges() {
        let image = Self.grey(width: 50, height: 70)
        let whole = BlurRenderer.apply(
            [CGRect(x: -20, y: -20, width: 200, height: 200)], to: image, scale: 1)
        #expect(whole.width == 50 && whole.height == 70)
        #expect(PixelBuffer(whole) != PixelBuffer(image))
        let outside = BlurRenderer.apply(
            [CGRect(x: 60, y: 0, width: 20, height: 20)], to: image, scale: 1)
        #expect(PixelBuffer(outside) == PixelBuffer(image))
        let empty = BlurRenderer.apply(
            [CGRect(x: 5, y: 5, width: 0, height: 9)], to: image, scale: 1)
        #expect(PixelBuffer(empty) == PixelBuffer(image))
    }

    @Test func blurIsAppliedBeforeCropAndCuts() {
        let image = Self.grey(width: 100, height: 300)
        let blur = Annotation(
            id: 1, shape: .blur(rect: CGRect(x: 0, y: 40, width: 100, height: 200)))
        let blurredOriginal = BlurRenderer.apply(
            [CGRect(x: 0, y: 40, width: 100, height: 200)], to: image, scale: 1)
        let crop = PixelRect(x: 10, y: 20, width: 80, height: 260)
        let edits = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 180)], crop: crop,
            annotations: [blur])
        let rendered = Renderer.render(image, edits: edits)
        let expected = Renderer.render(
            blurredOriginal,
            edits: EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 180)], crop: crop))
        #expect(PixelBuffer(rendered.image) == PixelBuffer(expected.image))
    }

    @Test func blurGolden() throws {
        let image = Fixtures.sheet(width: 360, height: 200)
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 50, y: 30, width: 180, height: 100)))
            ])
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-blur")
    }
}
