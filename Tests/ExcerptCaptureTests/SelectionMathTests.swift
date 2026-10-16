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

    @Test func dragOntoNextDisplayIsClampedBeforeTheSizeCheck() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let edge = SelectionMath.rect(
            from: CGPoint(x: 98, y: 10), to: CGPoint(x: 150, y: 60), within: bounds)
        #expect(edge == CGRect(x: 98, y: 10, width: 2, height: 50))
        #expect(!SelectionMath.isCapturable(edge))
    }

    @Test func startButtonCentresOnATallSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 28)
        #expect(
            SelectionMath.startButtonFrame(
                for: CGRect(x: 100, y: 100, width: 400, height: 300), size: size, in: bounds)
                == CGRect(x: 200, y: 236, width: 200, height: 28))
        #expect(
            SelectionMath.startButtonFrame(for: bounds, size: size, in: bounds)
                == CGRect(x: 400, y: 386, width: 200, height: 28))
    }

    @Test func startButtonSitsInTheHUDBelowThenAboveAShortSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 28)
        // The HUD (128 tall) goes 12 below the selection; the button sits at its centre.
        #expect(
            SelectionMath.startButtonFrame(
                for: CGRect(x: 100, y: 100, width: 400, height: 100), size: size, in: bounds)
                == CGRect(x: 200, y: 262, width: 200, height: 28))
        #expect(
            SelectionMath.startButtonFrame(
                for: CGRect(x: 100, y: 690, width: 400, height: 100), size: size, in: bounds)
                == CGRect(x: 200, y: 600, width: 200, height: 28))
        // The HUD (520 wide) clamps to the left edge; the button centres in it.
        #expect(
            SelectionMath.startButtonFrame(
                for: CGRect(x: 0, y: 100, width: 50, height: 50), size: size, in: bounds
            ).minX == 160)
    }

    @Test func startButtonLeavesASelectionTooShortForTheHUDToCentre() {
        // 200 tall: room to centre the 28pt button, not the 128pt HUD.
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = SelectionMath.startButtonFrame(
            for: CGRect(x: 100, y: 100, width: 400, height: 200),
            size: CGSize(width: 200, height: 28), in: bounds)
        #expect(frame.minY > 300)
    }
}
