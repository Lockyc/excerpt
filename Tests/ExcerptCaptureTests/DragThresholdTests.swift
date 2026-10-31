import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct DragThresholdTests {
    let press = CGPoint(x: 100, y: 100)

    @Test func aWobbleWithinTheDistanceStaysAClick() {
        #expect(!DragThreshold.isDrag(from: press, to: press))
        #expect(!DragThreshold.isDrag(from: press, to: CGPoint(x: 101, y: 99)))
        #expect(!DragThreshold.isDrag(from: press, to: CGPoint(x: 103, y: 100)))
    }

    @Test func travelPastTheDistanceIsADrag() {
        #expect(DragThreshold.isDrag(from: press, to: CGPoint(x: 103.5, y: 100)))
        #expect(DragThreshold.isDrag(from: press, to: CGPoint(x: 97, y: 97)))
    }
}
