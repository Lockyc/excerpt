import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct ControlBarPlacementTests {
    let screen = CGRect(x: 0, y: 25, width: 1000, height: 775)
    let bar = CGSize(width: 300, height: 40)

    @Test func barSitsInsideAtTheBottomCentre() {
        let area = CGRect(x: 100, y: 300, width: 400, height: 300)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen)
                == CGRect(x: 150, y: 308, width: 300, height: 40))
    }

    @Test func tallAreaWithRoomBesideKeepsTheBarInside() {
        let area = CGRect(x: 300, y: 0, width: 400, height: 800)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen)
                == CGRect(x: 350, y: 33, width: 300, height: 40))
    }

    @Test func fullScreenAreaInsetsBottom() {
        #expect(
            ControlBarPlacement.frame(bar: bar, area: screen, screen: screen)
                == CGRect(x: 350, y: 33, width: 300, height: 40))
    }

    @Test func smallAreaHasTheBarBelow() {
        let area = CGRect(x: 100, y: 300, width: 200, height: 100)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen)
                == CGRect(x: 50, y: 252, width: 300, height: 40))
    }

    @Test func smallAreaAtTheScreenBottomHasTheBarAbove() {
        let area = CGRect(x: 0, y: 25, width: 200, height: 100)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen)
                == CGRect(x: 0, y: 133, width: 300, height: 40))
    }
}
