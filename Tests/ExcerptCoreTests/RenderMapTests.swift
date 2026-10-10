import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct RenderMapTests {
    // A 200×300 original cropped to x 10..<190, y 20..<280, with rows 100..<150 removed
    // (crop-relative 80..<130) behind a 10px gap.
    let map = RenderMap(
        crop: PixelRect(x: 10, y: 20, width: 180, height: 260),
        rows: AxisMap(extent: 260, bands: [80..<130], gap: 10),
        columns: AxisMap(extent: 180, bands: [], gap: 10))

    @Test func pointsShiftByTheCropAndCollapseAcrossTheCut() {
        #expect(map.point(CGPoint(x: 10, y: 20)) == CGPoint(x: 0, y: 0))
        #expect(map.point(CGPoint(x: 50, y: 60)) == CGPoint(x: 40, y: 40))
        #expect(map.point(CGPoint(x: 50, y: 160)) == CGPoint(x: 40, y: 100))
        #expect(map.point(CGPoint(x: 50, y: 120)) == CGPoint(x: 40, y: 85))
    }

    @Test func aRectPartlyInsideACutKeepsOnlyItsVisiblePart() {
        // y 120..<170: rows 120..<150 are removed, 150..<170 are kept after the gap.
        let r = map.rect(CGRect(x: 20, y: 120, width: 30, height: 50))
        #expect(r == CGRect(x: 10, y: 90, width: 30, height: 20))
    }

    @Test func aRectWhollyInsideACutIsHidden() {
        let r = CGRect(x: 20, y: 105, width: 30, height: 40)
        #expect(map.isHidden(r))
        #expect(map.rect(r) == nil)
        #expect(!map.isHidden(CGRect(x: 20, y: 90, width: 30, height: 40)))
    }

    @Test func originalInvertsPoint() {
        let p = CGPoint(x: 70, y: 200)
        #expect(map.original(map.point(p)) == p)
    }

    @Test func seamsReportOriginalBandsAndRenderedGaps() {
        #expect(map.seams(.horizontal) == [Seam(axis: .horizontal, band: 100..<150, gap: 80..<90)])
        #expect(map.seams(.vertical).isEmpty)
        #expect(map.renderedWidth == 180 && map.renderedHeight == 220)
    }
}
