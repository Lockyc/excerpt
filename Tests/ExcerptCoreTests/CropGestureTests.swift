import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct CropGestureTests {
    /// A dark card at x 100..<300, y 80..<240 on a light diagonal gradient, which has neither a
    /// uniform line nor an edge of its own.
    let card = PixelBuffer(
        Fixtures.paint(width: 400, height: 320) { x, y in
            if (100..<300).contains(x) && (80..<240).contains(y) {
                return RGBA(r: 30, g: 30, b: 40, a: 255)
            }
            let v = UInt8(130 + (x + y) / 6)
            return RGBA(r: v, g: v, b: v, a: 255)
        })

    @Test func findsTheBoundaryNearestThePosition() {
        #expect(
            EdgeSnapper.edge(near: 106, axis: .vertical, in: card, radius: 12, span: 80..<240)
                == 100)
        #expect(
            EdgeSnapper.edge(near: 233, axis: .horizontal, in: card, radius: 12, span: 100..<300)
                == 240)
        // Too far, or along a span the card doesn't fill most of.
        #expect(
            EdgeSnapper.edge(near: 130, axis: .vertical, in: card, radius: 12, span: 80..<240)
                == nil)
        #expect(
            EdgeSnapper.edge(near: 100, axis: .vertical, in: card, radius: 12, span: 0..<320)
                == nil)
    }

    @Test func aCropDragSnapsToTheCardWhereNoLineIsUniform() {
        let crop = Gestures.crop(
            from: CGPoint(x: 94, y: 86), to: CGPoint(x: 305, y: 236), width: 400, height: 320,
            minimum: 8, snapping: card, radius: 12)
        #expect(crop == PixelRect(x: 100, y: 80, width: 200, height: 160))
        #expect(Gestures.cropGuides(crop!, in: card) == [.left, .right, .top, .bottom])
        #expect(
            Gestures.cropGuides(PixelRect(x: 90, y: 80, width: 210, height: 160), in: card)
                == [.right, .top, .bottom])
    }

    @Test func aHandleIsTheNearestSideOrCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(Gestures.cropEdges(of: rect, near: CGPoint(x: 103, y: 150), slop: 6) == .left)
        #expect(
            Gestures.cropEdges(of: rect, near: CGPoint(x: 298, y: 204), slop: 6)
                == [.right, .bottom])
        #expect(Gestures.cropEdges(of: rect, near: CGPoint(x: 200, y: 150), slop: 6) == [])
        #expect(Gestures.cropEdges(of: rect, near: CGPoint(x: 100, y: 230), slop: 6) == [])
    }

    @Test func draggingAHandleMovesOnlyItsSides() {
        let crop = PixelRect(x: 60, y: 40, width: 200, height: 150)
        let wider = Gestures.adjustingCrop(
            crop, edges: .right, to: CGPoint(x: 330, y: 999), width: 400, height: 320,
            minimum: 8, snapping: nil, radius: 0)
        #expect(wider == PixelRect(x: 60, y: 40, width: 270, height: 150))
        let corner = Gestures.adjustingCrop(
            crop, edges: [.left, .top], to: CGPoint(x: -20, y: 10), width: 400, height: 320,
            minimum: 8, snapping: nil, radius: 0)
        #expect(corner == PixelRect(x: 0, y: 10, width: 260, height: 180))
        // Dragged past the opposite side, an edge stops `minimum` short of it.
        let pinched = Gestures.adjustingCrop(
            crop, edges: .left, to: CGPoint(x: 390, y: 50), width: 400, height: 320,
            minimum: 8, snapping: nil, radius: 0)
        #expect(pinched == PixelRect(x: 252, y: 40, width: 8, height: 150))
    }

    @Test func aDraggedHandleSnapsToTheCard() {
        let snapped = Gestures.adjustingCrop(
            PixelRect(x: 20, y: 80, width: 360, height: 160), edges: .left,
            to: CGPoint(x: 109, y: 0), width: 400, height: 320, minimum: 8, snapping: card,
            radius: 12)
        #expect(snapped == PixelRect(x: 100, y: 80, width: 280, height: 160))
    }
}
