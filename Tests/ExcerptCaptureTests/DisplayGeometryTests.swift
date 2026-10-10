import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct DisplayGeometryTests {
    @Test func quartzAndAppKitAreMirrorImages() {
        let appKit = CGRect(x: 100, y: 700, width: 300, height: 200)
        let quartz = DisplayGeometry.quartzRect(fromAppKit: appKit, primaryHeight: 1000)
        #expect(quartz == CGRect(x: 100, y: 100, width: 300, height: 200))
        #expect(DisplayGeometry.appKitRect(fromQuartz: quartz, primaryHeight: 1000) == appKit)
    }

    @Test func pixelRectScalesRoundsOutwardAndClamps() {
        let r = DisplayGeometry.pixelRect(
            forLocalPoints: CGRect(x: 10.3, y: 5.6, width: 20.2, height: 10),
            scale: 2, imageSize: CGSize(width: 100, height: 100))
        #expect(r == CGRect(x: 20, y: 11, width: 41, height: 21))
        let clamped = DisplayGeometry.pixelRect(
            forLocalPoints: CGRect(x: 40, y: 40, width: 30, height: 30),
            scale: 2, imageSize: CGSize(width: 100, height: 100))
        #expect(clamped == CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    @Test func appKitAndLocalPointsAreInverses() {
        let display = CGRect(x: 1440, y: -200, width: 1000, height: 800)
        let local = CGRect(x: 30, y: 40, width: 100, height: 50)
        let appKit = DisplayGeometry.appKitRect(forLocalPoints: local, displayFrame: display)
        #expect(appKit == CGRect(x: 1470, y: 510, width: 100, height: 50))
        #expect(DisplayGeometry.localPoints(forAppKitRect: appKit, displayFrame: display) == local)
    }

    /// Stills taken before the selector are stale once a display is added, removed or moved;
    /// the order the displays are listed in doesn't matter.
    @Test func anArrangementChangesWhenADisplayIsAddedRemovedOrMoved() {
        let main = (CGDirectDisplayID(1), CGRect(x: 0, y: 0, width: 1440, height: 900))
        let side = (CGDirectDisplayID(2), CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let moved = (CGDirectDisplayID(2), CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        func changed(_ a: [(CGDirectDisplayID, CGRect)], _ b: [(CGDirectDisplayID, CGRect)]) -> Bool
        {
            DisplayGeometry.arrangementChanged(from: a, to: b)
        }
        #expect(!changed([main, side], [side, main]))
        #expect(changed([main, side], [main]))
        #expect(changed([main], [main, side]))
        #expect(changed([main, side], [main, moved]))
    }
}
