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
                [CGRect(x: 10, y: 10, width: 48, height: 48)], to: image, scale: 2, salt: 7))
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
            BlurRenderer.apply(
                [CGRect(x: 0, y: 0, width: 240, height: 24)], to: image, scale: 2, salt: 7))
        let colours = Set((0..<10).map { out[x: $0 * 24, y: 0].r })
        #expect(colours.count > 1)
        for c in colours { #expect(abs(Int(c) - 128) <= BlurRenderer.noiseAmplitude) }
    }

    @Test func identicalEditsGiveIdenticalPixels() {
        let image = Fixtures.sheet(width: 200, height: 200)
        let rects = [CGRect(x: 20, y: 30, width: 100, height: 60)]
        let a = BlurRenderer.apply(rects, to: image, scale: 2, salt: 7)
        let b = BlurRenderer.apply(rects, to: image, scale: 2, salt: 7)
        #expect(PixelBuffer(a) == PixelBuffer(b))
    }

    @Test func coversTheWholeImageAndClampsAtTheEdges() {
        let image = Self.grey(width: 50, height: 70)
        let whole = BlurRenderer.apply(
            [CGRect(x: -20, y: -20, width: 200, height: 200)], to: image, scale: 1, salt: 7)
        #expect(whole.width == 50 && whole.height == 70)
        #expect(PixelBuffer(whole) != PixelBuffer(image))
        let outside = BlurRenderer.apply(
            [CGRect(x: 60, y: 0, width: 20, height: 20)], to: image, scale: 1, salt: 7)
        #expect(PixelBuffer(outside) == PixelBuffer(image))
        let empty = BlurRenderer.apply(
            [CGRect(x: 5, y: 5, width: 0, height: 9)], to: image, scale: 1, salt: 7)
        #expect(PixelBuffer(empty) == PixelBuffer(image))
    }

    @Test func blurIsAppliedBeforeCropAndCuts() {
        let image = Self.grey(width: 100, height: 300)
        let blur = Annotation(
            id: 1, shape: .blur(rect: CGRect(x: 0, y: 40, width: 100, height: 200)))
        let blurredOriginal = BlurRenderer.apply(
            [CGRect(x: 0, y: 40, width: 100, height: 200)], to: image, scale: 1, salt: 7)
        let crop = PixelRect(x: 10, y: 20, width: 80, height: 260)
        let edits = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 180)], crop: crop,
            annotations: [blur], salt: 7)
        let rendered = Renderer.render(image, edits: edits)
        let expected = Renderer.render(
            blurredOriginal,
            edits: EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 180)], crop: crop,
                salt: 7))
        #expect(PixelBuffer(rendered.image) == PixelBuffer(expected.image))
    }

    @Test func blurGolden() throws {
        let image = Fixtures.sheet(width: 360, height: 200)
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 50, y: 30, width: 180, height: 100)))
            ], salt: 7)
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-blur")
    }

    @Test func translucentBlocksDoNotLetDetailThrough() {
        let image = Fixtures.paint(width: 60, height: 60) { x, y in
            (x + y) % 2 == 0 ? RGBA(r: 100, g: 0, b: 0, a: 100) : RGBA(r: 0, g: 0, b: 50, a: 50)
        }
        let out = PixelBuffer(
            BlurRenderer.apply(
                [CGRect(x: 0, y: 0, width: 24, height: 24)], to: image, scale: 2, salt: 7))
        for y in 0..<24 {
            for x in 0..<24 { #expect(out[x: x, y: y] == out[x: 0, y: 0]) }
        }
    }

    @Test func saltChangesTheNoiseAndEveryRectFieldFeedsTheSeed() {
        let r = PixelRect(x: 1, y: 2, width: 3, height: 4)
        #expect(BlurRenderer.seed(r, salt: 1) != BlurRenderer.seed(r, salt: 2))
        #expect(BlurRenderer.seed(r, salt: 1) == BlurRenderer.seed(r, salt: 1))
        for other in [
            PixelRect(x: 9, y: 2, width: 3, height: 4), PixelRect(x: 1, y: 9, width: 3, height: 4),
            PixelRect(x: 1, y: 2, width: 9, height: 4), PixelRect(x: 1, y: 2, width: 3, height: 9),
        ] { #expect(BlurRenderer.seed(r, salt: 1) != BlurRenderer.seed(other, salt: 1)) }
    }

    @Test func aHugeRectBlursTheWholeImage() {
        let image = Self.grey(width: 50, height: 70)
        let out = BlurRenderer.apply(
            [CGRect(x: -5e11, y: -5e11, width: 1e12, height: 1e12)], to: image, scale: 1, salt: 7)
        let whole = BlurRenderer.apply(
            [CGRect(x: 0, y: 0, width: 50, height: 70)], to: image, scale: 1, salt: 7)
        #expect(PixelBuffer(out) == PixelBuffer(whole))
        #expect(PixelBuffer(out) != PixelBuffer(image))
        let blurred = PixelBuffer(out)
        // Far corner and a block in the middle are blurred too: flat within their blocks.
        #expect(blurred[x: 49, y: 69] == blurred[x: 45, y: 65])
        #expect(blurred[x: 25, y: 35] == blurred[x: 27, y: 37])
    }

    @Test func overlappingBlursEachReadTheOriginal() {
        let image = Fixtures.sheet(width: 200, height: 200)
        let a = CGRect(x: 10, y: 10, width: 100, height: 100)
        let b = CGRect(x: 60, y: 60, width: 100, height: 100)
        let both = PixelBuffer(BlurRenderer.apply([a, b], to: image, scale: 2, salt: 7))
        let onlyB = PixelBuffer(BlurRenderer.apply([b], to: image, scale: 2, salt: 7))
        // The later blur wins in the overlap, and equals blurring B alone from the original.
        for (x, y) in [(70, 70), (100, 100), (150, 150)] {
            #expect(both[x: x, y: y] == onlyB[x: x, y: y])
        }
    }

    @Test func blocksNeverShrinkBelowTwelvePixels() {
        let image = Self.grey(width: 60, height: 60)
        let out = PixelBuffer(
            BlurRenderer.apply(
                [CGRect(x: 0, y: 0, width: 24, height: 24)], to: image, scale: 0.05, salt: 7))
        for y in 0..<12 {
            for x in 0..<12 { #expect(out[x: x, y: y] == out[x: 0, y: 0]) }
        }
    }

    @Test func noiseReflectsAtTheBoundsInsteadOfClamping() {
        #expect(BlurRenderer.reflected(-5, upTo: 255) == 5)
        #expect(BlurRenderer.reflected(260, upTo: 255) == 250)
        #expect(BlurRenderer.reflected(100, upTo: 255) == 100)
        let white = Fixtures.paint(width: 240, height: 24) { _, _ in
            RGBA(r: 255, g: 255, b: 255, a: 255)
        }
        let out = PixelBuffer(
            BlurRenderer.apply(
                [CGRect(x: 0, y: 0, width: 240, height: 24)], to: white, scale: 2, salt: 7))
        let colours = Set((0..<10).map { out[x: $0 * 24, y: 0].r })
        #expect(colours.count > 1)
    }
}
