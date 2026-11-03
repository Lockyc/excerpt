import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct PatchTests {
    let sheet = Fixtures.sheet(width: 600, height: 800)

    static func patch(
        id: Int = 1, _ rect: CGRect, color: AnnotationColor = .palette(.blue)
    ) -> Annotation {
        Annotation(id: id, shape: .patch(rect: rect, autoColor: false), color: color)
    }

    @Test func patchFillsSolidly() {
        let rect = CGRect(x: 100, y: 200, width: 150, height: 60)
        let edits = EditDocument(scale: 1, annotations: [Self.patch(rect)])
        let out = PixelBuffer(Renderer.render(sheet, edits: edits).image)
        let original = PixelBuffer(sheet)
        for y in 200..<260 {
            for x in 100..<250 { #expect(out[x: x, y: y] == Palette.blue.rgba) }
        }
        for (x, y) in [(99, 230), (250, 230), (150, 199), (150, 260)] {
            #expect(out[x: x, y: y] == original[x: x, y: y])
        }
    }

    @Test func aSampledColourFillsAsItIs() {
        let sampled = RGBA(r: 12, g: 34, b: 56, a: 255)
        let edits = EditDocument(
            scale: 1,
            annotations: [
                Self.patch(CGRect(x: 10, y: 10, width: 40, height: 40), color: .sampled(sampled))
            ])
        let out = PixelBuffer(Renderer.render(sheet, edits: edits).image)
        #expect(out[x: 30, y: 30] == sampled)
    }

    @Test func aDraggedBackwardsRectFillsToo() {
        let rect = CGRect(x: 250, y: 260, width: -150, height: -60)
        let edits = EditDocument(scale: 1, annotations: [Self.patch(rect)])
        let out = PixelBuffer(Renderer.render(sheet, edits: edits).image)
        #expect(out[x: 150, y: 230] == Palette.blue.rgba)
    }

    @Test func patchUnderTextDrawsBelowLaterText() {
        let patch = Self.patch(CGRect(x: 50, y: 50, width: 300, height: 100), color: .palette(.red))
        let text = Annotation(
            id: 2, shape: .text(origin: CGPoint(x: 60, y: 60), string: "Totals"),
            color: .palette(.black))
        let both = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 1, annotations: [patch, text])).image)
        let reversed = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 1, annotations: [text, patch])).image)
        let patchOnly = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 1, annotations: [patch])).image)
        // Text above the patch shows; text beneath it is wholly concealed.
        #expect(both != patchOnly)
        #expect(reversed == patchOnly)
    }

    @Test func patchInsideCutIsHidden() {
        let cut = Cut(axis: .horizontal, lower: 200, upper: 500)
        let patch = Self.patch(CGRect(x: 100, y: 300, width: 200, height: 100))
        let edits = EditDocument(scale: 1, cuts: [cut], annotations: [patch])
        let map = Renderer.renderBase(sheet, edits: edits).map
        #expect(AnnotationGeometry.hiddenCount(edits.annotations, map: map, scale: 1) == 1)
        let without = Renderer.render(sheet, edits: EditDocument(scale: 1, cuts: [cut]))
        #expect(
            PixelBuffer(Renderer.render(sheet, edits: edits).image) == PixelBuffer(without.image))
    }

    @Test func boundsAreTheRectWithNoStroke() {
        let rect = CGRect(x: 250, y: 260, width: -150, height: -60)
        let bounds = AnnotationGeometry.bounds(of: Self.patch(rect), scale: 2)
        #expect(bounds == rect.standardized)
    }

    @Test func clickingAnywhereInsideHitsThePatch() {
        let patch = Self.patch(CGRect(x: 100, y: 200, width: 150, height: 60))
        let map = Renderer.renderBase(sheet, edits: EditDocument(scale: 1)).map
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 175, y: 230), in: [patch], scale: 1, slop: 0, map: map) == 1)
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 300, y: 230), in: [patch], scale: 1, slop: 0, map: map) == nil)
    }

    @Test func offsetMovesThePatchAndKeepsAutoColor() {
        let shape = Shape.patch(rect: CGRect(x: 1, y: 2, width: 3, height: 4), autoColor: true)
        #expect(
            shape.offset(dx: 10, dy: 20)
                == .patch(rect: CGRect(x: 11, y: 22, width: 3, height: 4), autoColor: true))
        #expect(shape.isPatch)
        #expect(!Shape.rectangle(rect: .zero).isPatch)
    }

    @Test func patchRoundTripsThroughDocument() throws {
        let doc = EditDocument(
            scale: 2,
            annotations: [
                Annotation(
                    id: 1,
                    shape: .patch(rect: CGRect(x: 5, y: 6, width: 70, height: 20), autoColor: true),
                    color: .sampled(RGBA(r: 1, g: 2, b: 3, a: 255)))
            ])
        #expect(try EditDocument.decode(doc.encoded()) == doc)
    }

    @Test func patchGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 400)
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 300, upper: 340)],
            annotations: [
                Self.patch(
                    CGRect(x: 61, y: 41, width: 240, height: 38), color: .palette(.black)),
                Annotation(
                    id: 2, shape: .text(origin: CGPoint(x: 70, y: 48), string: "Redacted"),
                    color: .palette(.yellow), width: .thin),
                Self.patch(
                    id: 3, CGRect(x: 360, y: 100, width: 180, height: 60),
                    color: .sampled(RGBA(r: 240, g: 240, b: 240, a: 255))),
            ])
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-patch")
    }
}
