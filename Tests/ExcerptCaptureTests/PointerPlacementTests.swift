import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct PointerPlacementTests {
    let visible = CGRect(x: 0, y: 25, width: 1000, height: 775)
    let size = CGSize(width: 300, height: 200)

    @Test func frameIsCentredOnThePointer() {
        #expect(
            PointerPlacement.frame(size: size, centredOn: CGPoint(x: 500, y: 400), within: visible)
                == CGRect(x: 350, y: 300, width: 300, height: 200))
    }

    @Test func frameIsClampedInsideEachEdge() {
        func origin(_ pointer: CGPoint) -> CGPoint {
            PointerPlacement.frame(size: size, centredOn: pointer, within: visible).origin
        }
        #expect(origin(CGPoint(x: 5, y: 400)) == CGPoint(x: 0, y: 300))
        #expect(origin(CGPoint(x: 995, y: 400)) == CGPoint(x: 700, y: 300))
        #expect(origin(CGPoint(x: 500, y: 30)) == CGPoint(x: 350, y: 25))
        #expect(origin(CGPoint(x: 500, y: 799)) == CGPoint(x: 350, y: 600))
    }

    @Test func frameLargerThanTheScreenPinsToItsBottomLeft() {
        let small = CGRect(x: 100, y: 100, width: 200, height: 150)
        #expect(
            PointerPlacement.frame(size: size, centredOn: CGPoint(x: 200, y: 175), within: small)
                .origin == CGPoint(x: 100, y: 100))
    }

    @Test func safetyZoneReachesTheMarginAroundTheFrame() {
        let frame = CGRect(x: 350, y: 300, width: 300, height: 200)
        let m = PointerPlacement.safetyMargin
        #expect(PointerPlacement.isInSafetyZone(CGPoint(x: 500, y: 400), around: frame))
        #expect(PointerPlacement.isInSafetyZone(CGPoint(x: 350 - m + 1, y: 400), around: frame))
        #expect(!PointerPlacement.isInSafetyZone(CGPoint(x: 350 - m - 1, y: 400), around: frame))
        #expect(!PointerPlacement.isInSafetyZone(CGPoint(x: 500, y: 500 + m + 1), around: frame))
    }
}
