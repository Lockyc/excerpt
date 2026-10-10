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

    @Test func anAnnotationOverhangingAnEdgeBandDrawsOnlyItsKeptPart() {
        // Crop x 10..<190, y 20..<280 with rows 0..<30 (original 20..<50) removed.
        let m = RenderMap(
            crop: PixelRect(x: 10, y: 20, width: 180, height: 260),
            rows: AxisMap(extent: 260, bands: [0..<30], gap: 10),
            columns: AxisMap(extent: 180, bands: [], gap: 10))
        // Original y 10..<60 spans off the crop's top edge, the band, then 10 kept rows.
        #expect(
            m.rect(CGRect(x: 20, y: 10, width: 30, height: 50))
                == CGRect(x: 10, y: 10, width: 30, height: 10))
    }

    @Test func aCropEntirelyInsideABandHidesEverything() {
        let m = RenderMap(
            crop: PixelRect(x: 0, y: 100, width: 50, height: 40),
            rows: AxisMap(extent: 40, bands: [0..<40], gap: 10),
            columns: AxisMap(extent: 50, bands: [], gap: 10))
        #expect(m.renderedHeight == 10)
        #expect(m.isHidden(CGRect(x: 5, y: 110, width: 10, height: 10)))
        #expect(m.rect(CGRect(x: 5, y: 110, width: 10, height: 10)) == nil)
        #expect(m.point(CGPoint(x: 5, y: 120)) == CGPoint(x: 5, y: 5))
    }

    @Test func verticalSeamsOffsetByTheCropAndColumnsCut() {
        let m = RenderMap(
            crop: PixelRect(x: 10, y: 20, width: 180, height: 260),
            rows: AxisMap(extent: 260, bands: [], gap: 10),
            columns: AxisMap(extent: 180, bands: [40..<60], gap: 10))
        #expect(m.seams(.vertical) == [Seam(axis: .vertical, band: 50..<70, gap: 40..<50)])
        #expect(m.point(CGPoint(x: 100, y: 30)) == CGPoint(x: 80, y: 10))
        #expect(m.point(CGPoint(x: 60, y: 30)) == CGPoint(x: 45, y: 10))
        // Original x 40..<90 is crop-relative 30..<80: the band 40..<60 is cut from its middle.
        #expect(
            m.rect(CGRect(x: 40, y: 30, width: 50, height: 10))
                == CGRect(x: 30, y: 10, width: 40, height: 10))
        #expect(m.original(CGPoint(x: 80, y: 10)) == CGPoint(x: 100, y: 30))
    }
}
