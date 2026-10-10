import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct SelectionMathTests {
    @Test func rectIsNormalisedWhicheverWayYouDrag() {
        #expect(
            SelectionMath.rect(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 60))
                == CGRect(x: 10, y: 40, width: 40, height: 20))
    }

    @Test func clicksAndSliversAreNotCapturable() {
        #expect(!SelectionMath.isCapturable(.zero))
        #expect(!SelectionMath.isCapturable(CGRect(x: 0, y: 0, width: 300, height: 3)))
        #expect(SelectionMath.isCapturable(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }
}
