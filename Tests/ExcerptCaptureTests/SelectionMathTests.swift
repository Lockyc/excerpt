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

    @Test func aPressGripsTheEdgesItIsNearAndMovesFromInside() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(SelectionMath.grip(at: CGPoint(x: 200, y: 150), on: rect) == [])
        #expect(SelectionMath.grip(at: CGPoint(x: 97, y: 150), on: rect) == .left)
        #expect(SelectionMath.grip(at: CGPoint(x: 304, y: 204), on: rect) == [.right, .bottom])
        #expect(SelectionMath.grip(at: CGPoint(x: 200, y: 99), on: rect) == .top)
        #expect(SelectionMath.grip(at: CGPoint(x: 90, y: 150), on: rect) == nil)
        // A selection narrower than both reaches grips the nearer edge only.
        let thin = CGRect(x: 100, y: 100, width: 6, height: 100)
        #expect(SelectionMath.grip(at: CGPoint(x: 101, y: 150), on: thin) == .left)
        #expect(SelectionMath.grip(at: CGPoint(x: 105, y: 150), on: thin) == .right)
    }

    @Test func movingKeepsTheSizeAndStaysOnTheDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(
            SelectionMath.adjust(rect, grip: [], by: CGSize(width: 50, height: -20), within: bounds)
                == CGRect(x: 150, y: 80, width: 200, height: 100))
        #expect(
            SelectionMath.adjust(
                rect, grip: [], by: CGSize(width: 2000, height: -500), within: bounds)
                == CGRect(x: 800, y: 0, width: 200, height: 100))
    }

    @Test func resizingMovesOnlyTheGrippedEdgesAndFlipsPastTheOpposite() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(
            SelectionMath.adjust(
                rect, grip: [.right, .bottom], by: CGSize(width: 30, height: 40), within: bounds)
                == CGRect(x: 100, y: 100, width: 230, height: 140))
        #expect(
            SelectionMath.adjust(
                rect, grip: .left, by: CGSize(width: 50, height: 99), within: bounds)
                == CGRect(x: 150, y: 100, width: 150, height: 100))
        #expect(
            SelectionMath.adjust(
                rect, grip: .left, by: CGSize(width: 250, height: 0), within: bounds)
                == CGRect(x: 300, y: 100, width: 50, height: 100))
        #expect(
            SelectionMath.adjust(
                rect, grip: .top, by: CGSize(width: 0, height: -500), within: bounds)
                == CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    @Test func theModeBarCentresInARoomySelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 400, height: 60)
        #expect(
            SelectionMath.barFrame(
                for: CGRect(x: 100, y: 100, width: 600, height: 400), cursor: .zero, size: size,
                in: bounds) == CGRect(x: 200, y: 270, width: 400, height: 60))
    }

    @Test func theModeBarSitsBelowThenAboveASmallSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 400, height: 60)
        #expect(
            SelectionMath.barFrame(
                for: CGRect(x: 300, y: 100, width: 100, height: 50), cursor: .zero, size: size,
                in: bounds) == CGRect(x: 150, y: 162, width: 400, height: 60))
        #expect(
            SelectionMath.barFrame(
                for: CGRect(x: 0, y: 700, width: 100, height: 100), cursor: .zero, size: size,
                in: bounds) == CGRect(x: 0, y: 628, width: 400, height: 60))
        // A selection filling the display's height: inside its bottom edge.
        #expect(
            SelectionMath.barFrame(
                for: CGRect(x: 100, y: 0, width: 300, height: 800), cursor: .zero, size: size,
                in: bounds) == CGRect(x: 50, y: 728, width: 400, height: 60))
    }

    @Test func withNoSelectionTheModeBarSitsJustBelowThePointer() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 400, height: 60)
        #expect(
            SelectionMath.barFrame(
                for: nil, cursor: CGPoint(x: 500, y: 300), size: size, in: bounds)
                == CGRect(x: 300, y: 324, width: 400, height: 60))
        #expect(
            SelectionMath.barFrame(
                for: nil, cursor: CGPoint(x: 950, y: 790), size: size, in: bounds)
                == CGRect(x: 600, y: 706, width: 400, height: 60))
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
