import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct ScrollRegionTests {
    // A 1440×900pt Retina display to the right of a 1920×1080 primary, bottoms aligned.
    let display = CGRect(x: 1920, y: 0, width: 1440, height: 900)

    @Test func everySpaceDerivesFromThePixelRect() {
        let region = ScrollRegion(
            displayID: 2, displayFrame: display, scale: 2,
            pixelRect: CGRect(x: 200, y: 100, width: 800, height: 1200), primaryHeight: 1080)
        #expect(region.localPoints == CGRect(x: 100, y: 50, width: 400, height: 600))
        #expect(region.appKitFrame == CGRect(x: 2020, y: 250, width: 400, height: 600))
        // Quartz: the display's top is at 1080 - 900 = 180 below the primary's top.
        #expect(region.quartzCentre == CGPoint(x: 2220, y: 180 + 350))
        #expect(region.stepPoints == 360)
    }

    @Test func aOneTimesRegionSteps60PercentOfItsPoints() {
        let region = ScrollRegion(
            displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1,
            pixelRect: CGRect(x: 0, y: 0, width: 500, height: 500), primaryHeight: 1080)
        #expect(region.stepPoints == 300)
        #expect(region.quartzCentre == CGPoint(x: 250, y: 250))
    }

    @Test func localPointsUndoPixelRect() {
        let local = CGRect(x: 10, y: 20, width: 30, height: 40)
        let pixels = DisplayGeometry.pixelRect(
            forLocalPoints: local, scale: 2, imageSize: CGSize(width: 1000, height: 1000))
        #expect(DisplayGeometry.localPoints(forPixelRect: pixels, scale: 2) == local)
    }
}

@Suite struct ScrollChromeLayoutTests {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func previewGoesRightThenLeftThenInside() {
        let middle = CGRect(x: 400, y: 200, width: 500, height: 500)
        #expect(
            ScrollChromeLayout.preview(region: middle, visible: visible)
                == CGRect(x: 912, y: 200, width: 180, height: 500))
        let right = CGRect(x: 1100, y: 200, width: 300, height: 500)
        #expect(ScrollChromeLayout.preview(region: right, visible: visible).maxX == 1088)
        let full = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(
            ScrollChromeLayout.preview(region: full, visible: visible)
                == CGRect(x: 1248, y: 0, width: 180, height: 875))
    }

    @Test func hudGoesBelowThenAboveThenInside() {
        let size = CGSize(width: 460, height: 76)
        let middle = CGRect(x: 400, y: 200, width: 500, height: 500)
        #expect(
            ScrollChromeLayout.hud(size: size, region: middle, visible: visible)
                == CGRect(x: 420, y: 112, width: 460, height: 76))
        let low = CGRect(x: 400, y: 20, width: 500, height: 500)
        #expect(ScrollChromeLayout.hud(size: size, region: low, visible: visible).minY == 532)
        let full = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(
            ScrollChromeLayout.hud(size: size, region: full, visible: visible)
                == CGRect(x: 490, y: 12, width: 460, height: 76))
    }

    @Test func hudStaysOnScreenBesideAnEdgeRegion() {
        let size = CGSize(width: 460, height: 76)
        let edge = CGRect(x: 0, y: 300, width: 100, height: 300)
        #expect(ScrollChromeLayout.hud(size: size, region: edge, visible: visible).minX == 0)
    }
}
