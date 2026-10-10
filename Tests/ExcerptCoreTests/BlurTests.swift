import CoreGraphics
import ExcerptTestSupport
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

    @Test func blocksGrowToHalfTheShorterSide() {
        // Small rects keep the 12-point floor, at the scale.
        #expect(
            BlurRenderer.blockPixels(for: PixelRect(x: 0, y: 0, width: 300, height: 20), scale: 1)
                == 12)
        #expect(
            BlurRenderer.blockPixels(for: PixelRect(x: 0, y: 0, width: 300, height: 40), scale: 2)
                == 24)
        // Larger ones take half the shorter side, rounded up, whichever side that is.
        #expect(
            BlurRenderer.blockPixels(for: PixelRect(x: 0, y: 0, width: 1000, height: 126), scale: 1)
                == 63)
        #expect(
            BlurRenderer.blockPixels(for: PixelRect(x: 0, y: 0, width: 251, height: 900), scale: 2)
                == 126)
        #expect(
            BlurRenderer.blockPixels(for: PixelRect(x: 0, y: 0, width: 50, height: 50), scale: 3)
                == 36)
    }

    @Test func aTallLineIsAtMostTwoBlocksHigh() {
        let image = Self.grey(width: 600, height: 300)
        let out = PixelBuffer(
            BlurRenderer.apply(
                [CGRect(x: 0, y: 20, width: 600, height: 240)], to: image, scale: 2, salt: 7))
        // 240 pixels high → 120-pixel blocks: rows 20..<140 and 140..<260, five blocks across.
        for y in stride(from: 20, to: 140, by: 7) {
            for x in stride(from: 0, to: 120, by: 7) {
                #expect(out[x: x, y: y] == out[x: 0, y: 20])
            }
        }
        #expect(out[x: 0, y: 140] != out[x: 0, y: 20])
        #expect(out[x: 120, y: 20] != out[x: 0, y: 20])
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
        #expect(BlurRenderer.seed([r], salt: 1) != BlurRenderer.seed([r], salt: 2))
        #expect(BlurRenderer.seed([r], salt: 1) == BlurRenderer.seed([r], salt: 1))
        for other in [
            PixelRect(x: 9, y: 2, width: 3, height: 4), PixelRect(x: 1, y: 9, width: 3, height: 4),
            PixelRect(x: 1, y: 2, width: 9, height: 4), PixelRect(x: 1, y: 2, width: 3, height: 9),
        ] { #expect(BlurRenderer.seed([r], salt: 1) != BlurRenderer.seed([other], salt: 1)) }
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

    @Test func blursCloserThanAMinimumBlockAreOneGroup() {
        let a = PixelRect(x: 0, y: 0, width: 10, height: 10)
        let touching = PixelRect(x: 10, y: 0, width: 10, height: 10)
        let corner = PixelRect(x: 20, y: 10, width: 5, height: 5)
        let apart = PixelRect(x: 40, y: 40, width: 5, height: 5)
        let nested = PixelRect(x: 41, y: 41, width: 2, height: 2)
        #expect(
            BlurRenderer.groups([a, apart, touching, nested, corner], reach: 1)
                == [[a, touching, corner], [apart, nested]])
        #expect(
            BlurRenderer.groups([a, PixelRect(x: 11, y: 0, width: 5, height: 5)], reach: 1).count
                == 2)
        // Under `reach` apart on both axes joins; `reach` or more apart on either does not.
        let near = PixelRect(x: 21, y: 21, width: 5, height: 5)
        #expect(BlurRenderer.groups([a, near], reach: 12).count == 1)
        #expect(BlurRenderer.groups([a, near], reach: 11).count == 2)
        let stacked = (0..<6).map { PixelRect(x: 0, y: $0 * 22, width: 300, height: 20) }
        #expect(BlurRenderer.groups(stacked, reach: 3) == [stacked])
        #expect(BlurRenderer.groups(stacked, reach: 2).count == 6)
        #expect(BlurRenderer.minimumBlock(scale: 2) == 24)
        #expect(BlurRenderer.minimumBlock(scale: 0.5) == 12)
        #expect(
            BlurRenderer.boundingBox([a, corner]) == PixelRect(x: 0, y: 0, width: 25, height: 15))
    }

    /// Thin strips stacked over a line, or a small blur nested in a large one, pixelate as one:
    /// blocks sized from the group's box, on one grid, as if drawn as the one rect they cover.
    @Test func stackedAndNestedBlursUseTheGroupsBlocks() {
        let image = Fixtures.sheet(width: 600, height: 300)
        let whole = CGRect(x: 0, y: 20, width: 600, height: 240)
        let strips = (0..<6).map { CGRect(x: 0, y: 20 + $0 * 40, width: 600, height: 40) }
        let one = PixelBuffer(BlurRenderer.apply([whole], to: image, scale: 2, salt: 7))
        let stacked = PixelBuffer(BlurRenderer.apply(strips, to: image, scale: 2, salt: 7))
        // 120-pixel blocks: flat across what were six 40-pixel strips.
        for y in stride(from: 20, to: 140, by: 7) {
            #expect(stacked[x: 3, y: y] == stacked[x: 3, y: 20])
        }
        #expect(stacked[x: 0, y: 140] != stacked[x: 0, y: 20])
        let nested = PixelBuffer(
            BlurRenderer.apply(
                [whole, CGRect(x: 200, y: 100, width: 60, height: 30)], to: image, scale: 2,
                salt: 7))
        for y in stride(from: 100, to: 130, by: 3) {
            for x in stride(from: 200, to: 240, by: 3) {
                #expect(nested[x: x, y: y] == nested[x: 120, y: 20])
            }
        }
        #expect(one[x: 0, y: 0] == PixelBuffer(image)[x: 0, y: 0])
    }

    /// Blocks fill the group's rects, never the rest of its bounding box.
    @Test func pixelsOutsideEveryRectOfAGroupAreUntouched() {
        let image = Fixtures.sheet(width: 200, height: 200)
        let original = PixelBuffer(image)
        let out = PixelBuffer(
            BlurRenderer.apply(
                [
                    CGRect(x: 0, y: 0, width: 100, height: 20),
                    CGRect(x: 0, y: 20, width: 20, height: 100),
                ], to: image, scale: 1, salt: 7))
        for (x, y) in [(50, 50), (99, 119), (21, 21)] {
            #expect(out[x: x, y: y] == original[x: x, y: y])
        }
        #expect(out != original)
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
