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
