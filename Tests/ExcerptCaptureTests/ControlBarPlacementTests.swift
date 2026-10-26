import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct ControlBarPlacementTests {
    let screen = CGRect(x: 0, y: 25, width: 1000, height: 775)
    let bar = CGSize(width: 300, height: 40)

    @Test func barSitsBelowCentred() {
        let area = CGRect(x: 100, y: 300, width: 400, height: 300)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen, otherScreens: [])
                == CGRect(x: 150, y: 252, width: 300, height: 40))
    }

    @Test func barGoesAboveAtTheScreenBottom() {
        let area = CGRect(x: 100, y: 25, width: 400, height: 300)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen, otherScreens: [])
                == CGRect(x: 150, y: 333, width: 300, height: 40))
    }

    @Test func barGoesBesideWhenNeitherFits() {
        let area = CGRect(x: 100, y: 30, width: 400, height: 765)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: area, screen: screen, otherScreens: [])
                == CGRect(x: 508, y: 392.5, width: 300, height: 40))
        let right = CGRect(x: 600, y: 30, width: 395, height: 765)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: right, screen: screen, otherScreens: [])
                == CGRect(x: 292, y: 392.5, width: 300, height: 40))
    }

    @Test func fullScreenAreaUsesAnotherScreen() {
        let other = CGRect(x: 1000, y: 0, width: 800, height: 600)
        #expect(
            ControlBarPlacement.frame(bar: bar, area: screen, screen: screen, otherScreens: [other])
                == CGRect(x: 1250, y: 8, width: 300, height: 40))
    }

    @Test func fullScreenAreaAloneInsetsBottom() {
        #expect(
            ControlBarPlacement.frame(bar: bar, area: screen, screen: screen, otherScreens: [])
                == CGRect(x: 350, y: 33, width: 300, height: 40))
    }
}
