import CoreGraphics
import ExcerptCore
import Foundation
import Testing

@testable import ExcerptEditor

@Suite struct PatchToolTests {
    static let left = RGBA(r: 240, g: 240, b: 240, a: 255)
    static let right = RGBA(r: 30, g: 60, b: 120, a: 255)
    static let margin = RGBA(r: 9, g: 99, b: 199, a: 255)

    /// A 100x100 capture: `left` for x < 50, `right` from there.
    func model(marginColor: RGBA? = nil) -> EditorModel {
        var bytes: [UInt8] = []
        for _ in 0..<100 {
            for x in 0..<100 {
                let c = x < 50 ? Self.left : Self.right
                bytes += [c.r, c.g, c.b, 255]
            }
        }
        let m = EditorModel(
            original: PixelBuffer(width: 100, height: 100, bytes: bytes).makeImage(),
            document: EditDocument(scale: 1, marginColor: marginColor, salt: 3))
        m.tool = .patch
        return m
    }

    func map(_ m: EditorModel) -> RenderMap {
        Renderer.renderBase(m.original, edits: m.baseDocument).map
    }

    func drag(_ m: EditorModel, _ from: (Double, Double), _ to: (Double, Double)) {
        let map = map(m)
        func p(_ v: (Double, Double)) -> Pointer {
            Pointer(rendered: CGPoint(x: v.0, y: v.1), map: map, slack: 200)
        }
        m.mouseDown(p(from), map: map)
        m.mouseDragged(p(to), map: map, snap: false)
        m.mouseUp(p(to), map: map, snap: false)
    }

    @Test func patchTakesGroundColour() {
        let m = model()
        drag(m, (5, 5), (25, 25))
        #expect(m.document.annotations.count == 1)
        let patch = m.document.annotations[0]
        #expect(
            patch.shape == .patch(rect: CGRect(x: 5, y: 5, width: 20, height: 20), autoColor: true))
        #expect(patch.color == .sampled(Self.left))
        #expect(m.selection == .annotation(patch.id))
    }

    @Test func movingAutoPatchResamples() {
        let m = model()
        drag(m, (5, 5), (25, 25))
        drag(m, (15, 15), (80, 15))
        #expect(m.document.annotations.count == 1)
        let patch = m.document.annotations[0]
        #expect(
            patch.shape == .patch(rect: CGRect(x: 70, y: 5, width: 20, height: 20), autoColor: true)
        )
        #expect(patch.color == .sampled(Self.right))
        m.undo()
        #expect(m.document.annotations[0].color == .sampled(Self.left))
    }

    @Test func colouredPatchStaysColoured() {
        let m = model()
        drag(m, (5, 5), (25, 25))
        m.setColor(.palette(.green))
        drag(m, (15, 15), (80, 15))
        #expect(m.document.annotations[0].color == .palette(.green))
        #expect(m.document.annotations[0].shape.isPatchWithAutoColor == false)
    }

    @Test func patchInMarginFallsBackToMarginColour() {
        let m = model(marginColor: Self.margin)
        drag(m, (-60, -60), (-20, -20))
        #expect(m.document.annotations.count == 1)
        #expect(m.document.annotations[0].color == .sampled(Self.margin))
    }

    @Test func patchInMarginWithoutMarginColourUsesTheStyleColour() {
        let m = model()
        drag(m, (-60, -60), (-20, -20))
        #expect(m.document.annotations[0].color == .sampled(m.style.color.rgba))
    }

    @Test func aTinyDragMakesNoPatch() {
        let m = model()
        drag(m, (5, 5), (6, 6))
        #expect(m.document.annotations.isEmpty)
    }

    @Test func patchToolIsOnE() {
        #expect(Tool(key: "e") == .patch)
        #expect(Tool.patch.title == "Patch")
        #expect(Tool.patch.symbol == "square.fill")
    }

    @Test func aSelectedPatchOffersColourAndDelete() {
        let m = model()
        drag(m, (5, 5), (25, 25))
        let color = m.document.annotations[0].color
        #expect(m.itemOptions == [.color(color, sample: color.rgba), .delete])
    }
}

extension Shape {
    fileprivate var isPatchWithAutoColor: Bool {
        if case .patch(_, let auto) = self { return auto }
        return false
    }
}
