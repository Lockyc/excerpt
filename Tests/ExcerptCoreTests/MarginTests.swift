import CoreGraphics
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct MarginTests {
    let sheet = Fixtures.sheet(width: 200, height: 100)
    let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    let overflowing = Annotation(
        id: 1, shape: .rectangle(rect: CGRect(x: -30, y: 20, width: 60, height: 40)))

    func doc(_ annotations: [Annotation], color: RGBA?, cuts: [Cut] = []) -> EditDocument {
        EditDocument(scale: 1, cuts: cuts, annotations: annotations, marginColor: color, salt: 1)
    }

    @Test func aRectanglePastTheLeftEdgeGrowsTheLeft() {
        let edits = doc([overflowing], color: red)
        let bounds = AnnotationGeometry.bounds(of: overflowing, scale: 1)
        let left = Int((-bounds.minX + Renderer.marginGap).rounded(.up))
        let map = Renderer.map(width: 200, height: 100, edits: edits)
        #expect(map.margin == Margin(left: left))
        let render = Renderer.render(sheet, edits: edits)
        #expect(render.image.width == 200 + left && render.image.height == 100)
        #expect(PixelBuffer(render.image)[x: 2, y: 5] == red)
    }

    @Test func insideMeansNoMargin() {
        let inside = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 30, y: 20, width: 60, height: 40)))
        let grown = Renderer.render(sheet, edits: doc([inside], color: red))
        let plain = Renderer.render(sheet, edits: doc([inside], color: nil))
        #expect(PixelBuffer(grown.image) == PixelBuffer(plain.image))
    }

    @Test func noMarginColorKeepsClipping() {
        let render = Renderer.render(sheet, edits: doc([overflowing], color: nil))
        #expect(render.image.width == 200)
    }

    @Test func blursAndHiddenAnnotationsNeverGrow() {
        let blur = Annotation(
            id: 1, shape: .blur(rect: CGRect(x: -30, y: 20, width: 60, height: 40)))
        #expect(
            Renderer.map(width: 200, height: 100, edits: doc([blur], color: red)).margin == .zero)
        let hidden = Annotation(
            id: 2, shape: .rectangle(rect: CGRect(x: -30, y: 40, width: 60, height: 10)))
        let cut = Cut(axis: .horizontal, lower: 30, upper: 60)
        #expect(
            Renderer.map(width: 200, height: 100, edits: doc([hidden], color: red, cuts: [cut]))
                .margin == .zero)
    }

    @Test func aSavedMarginReproducesFromTheMaster() {
        let edits = doc([overflowing], color: red)
        let render = Renderer.render(sheet, edits: edits)
        #expect(MasterFile.reproduces(PixelBuffer(render.image), from: sheet, edits: edits))
    }

    @Test func theMarginColourRoundTrips() throws {
        let edits = doc([overflowing], color: red)
        #expect(try EditDocument.decode(edits.encoded()) == edits)
        let v6 = try EditDocument.decode(Data(#"{"version":6,"scale":2,"cuts":[]}"#.utf8))
        #expect(v6.marginColor == nil)
    }
}

@Suite struct MarginAdoptionAndCropTests {
    let grey = RGBA(r: 0xE5, g: 0xE5, b: 0xEA, a: 255)

    @Test func aDocumentTakesTheColourOnlyWhenItsRenderStaysTheSame() {
        var clean = EditDocument(
            scale: 1,
            annotations: [
                Annotation(
                    id: 1, shape: .rectangle(rect: CGRect(x: 30, y: 20, width: 60, height: 40)))
            ], salt: 1)
        clean.adoptMarginColor(grey, width: 200, height: 100)
        #expect(clean.marginColor == grey)

        var touching = EditDocument(
            scale: 1,
            annotations: [
                Annotation(
                    id: 1, shape: .rectangle(rect: CGRect(x: 0, y: 20, width: 60, height: 40)))
            ], salt: 1)
        touching.adoptMarginColor(grey, width: 200, height: 100)
        #expect(touching.marginColor == nil)

        var far = EditDocument(
            scale: 1,
            annotations: [
                Annotation(
                    id: 1,
                    shape: .text(
                        origin: CGPoint(x: -EditDocument.coordinateLimit, y: 10), string: "x"))
            ], salt: 1)
        far.adoptMarginColor(grey, width: 200, height: 100)
        #expect(far.marginColor == nil)
        #expect(Renderer.map(width: 200, height: 100, edits: far).renderedWidth == 200)
    }

    @Test func aCropDropsWhatItPushesOutOfView() {
        let inside = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 150, y: 20, width: 20, height: 20)))
        let kept = Annotation(
            id: 2, shape: .rectangle(rect: CGRect(x: 10, y: 20, width: 20, height: 20)))
        var doc = EditDocument(scale: 1, annotations: [inside, kept], marginColor: grey, salt: 1)
        doc.setCrop(PixelRect(x: 0, y: 0, width: 100, height: 100), width: 200, height: 100)
        #expect(doc.annotations.map(\.id) == [2])
        #expect(doc.crop == PixelRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func aCaptionAlreadyOutsideTheCropStaysWhenTheCropChanges() {
        let caption = Annotation(
            id: 1, shape: .text(origin: CGPoint(x: 10, y: 5), string: "Caption"))
        var doc = EditDocument(
            scale: 1, crop: PixelRect(x: 0, y: 50, width: 200, height: 50),
            annotations: [caption], marginColor: grey, salt: 1)
        doc.setCrop(PixelRect(x: 0, y: 60, width: 200, height: 40), width: 200, height: 100)
        #expect(doc.annotations.map(\.id) == [1])
        doc.setCrop(nil, width: 200, height: 100)
        #expect(doc.annotations.map(\.id) == [1])
    }
}
