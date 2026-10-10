import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct CropTests {
    @Test func cropKeepsExactlyTheRegion() {
        let image = Fixtures.rowStripes(width: 40, height: 300)
        let edits = EditDocument(scale: 1, crop: PixelRect(x: 5, y: 100, width: 20, height: 50))
        let result = Renderer.render(image, edits: edits)
        #expect(result.image.width == 20 && result.image.height == 50)
        let buffer = PixelBuffer(result.image)
        #expect(buffer[x: 0, y: 0] == Fixtures.rowColor(100))
        #expect(buffer[x: 19, y: 49] == Fixtures.rowColor(149))
        #expect(result.map.crop == PixelRect(x: 5, y: 100, width: 20, height: 50))
    }

    @Test func aCropOffTheImageIsClampedAndAnEmptyOneIgnored() {
        let image = Fixtures.rowStripes(width: 40, height: 300)
        let over = EditDocument(scale: 1, crop: PixelRect(x: -10, y: 250, width: 100, height: 100))
        let clamped = Renderer.render(image, edits: over).image
        #expect(clamped.width == 40 && clamped.height == 50)
        let outside = EditDocument(scale: 1, crop: PixelRect(x: 50, y: 0, width: 10, height: 10))
        #expect(Renderer.render(image, edits: outside).image.height == 300)
    }

    @Test func cutsAreInOriginalPixelsUnderACrop() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let edits = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 150, upper: 250)],
            crop: PixelRect(x: 0, y: 100, width: 40, height: 250))
        let result = Renderer.render(image, edits: edits)
        let gap = SeamStyle.standard.gapPixels(scale: 1)
        #expect(result.image.height == 250 - 100 + gap)
        #expect(result.map.seams(.horizontal).map(\.band) == [150..<250])
        let after = result.map.rows.gaps[0].destination.upperBound
        #expect(PixelBuffer(result.image)[x: 2, y: after + 20] == Fixtures.rowColor(270))
    }

    @Test func aCutOutsideTheCropChangesNothing() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let crop = PixelRect(x: 0, y: 0, width: 40, height: 300)
        let plain = Renderer.render(image, edits: EditDocument(scale: 1, crop: crop)).image
        let cut = Renderer.render(
            image,
            edits: EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 320, upper: 380)], crop: crop)
        ).image
        #expect(PixelBuffer(cut) == PixelBuffer(plain))
    }

    @Test func aCutStraddlingTheCropEdgeIsTrimmedToIt() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let edits = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 250, upper: 380)],
            crop: PixelRect(x: 0, y: 0, width: 40, height: 300))
        let result = Renderer.render(image, edits: edits)
        #expect(result.image.height == 250 + SeamStyle.standard.gapPixels(scale: 1))
        #expect(result.map.rows.gaps.map(\.removed) == [50])
        #expect(result.map.seams(.horizontal).map(\.band) == [250..<300])
    }

    @Test func aCropWhollyInsideACutEqualsThePlainCrop() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let crop = PixelRect(x: 0, y: 160, width: 40, height: 50)
        let plain = Renderer.render(image, edits: EditDocument(scale: 1, crop: crop))
        let cut = Renderer.render(
            image,
            edits: EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 150, upper: 250)], crop: crop))
        #expect(PixelBuffer(cut.image) == PixelBuffer(plain.image))
        #expect(cut.map.rows.gaps.isEmpty)
    }

    @Test func theSameCutTearsTheSameUnderDifferentCrops() {
        let image = Fixtures.rowStripes(width: 40, height: 400)
        let cut = Cut(axis: .horizontal, lower: 150, upper: 250)
        func strip(cropY: Int) -> PixelBuffer {
            let result = Renderer.render(
                image,
                edits: EditDocument(
                    scale: 1, cuts: [cut], crop: PixelRect(x: 0, y: cropY, width: 40, height: 200)))
            let gap = result.map.rows.gaps[0].destination
            let rect = CGRect(x: 0, y: gap.lowerBound - 10, width: 40, height: gap.count + 20)
            return PixelBuffer(result.image.cropping(to: rect)!)
        }
        #expect(strip(cropY: 100) == strip(cropY: 120))
    }

    @Test func cropAndCutGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 800)
        let edits = EditDocument(
            scale: 2,
            cuts: [
                Cut(axis: .horizontal, lower: 161, upper: 481),
                Cut(axis: .vertical, lower: 0, upper: 61),
            ],
            crop: PixelRect(x: 30, y: 41, width: 450, height: 600))
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-crop-and-cut")
    }
}
