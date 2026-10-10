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
}
