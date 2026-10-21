import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct RenderMapMarginTests {
    let margin = Margin(top: 10, left: 20, bottom: 0, right: 5)

    func map(bands: [Range<Int>] = []) -> RenderMap {
        RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 100, height: 50),
            rows: AxisMap(extent: 50, bands: bands, gap: 6),
            columns: AxisMap(extent: 100, bands: [], gap: 6)
        ).withMargin(margin)
    }

    @Test func theMarginShiftsPlacementAndGrowsTheSize() {
        let m = map()
        #expect(m.point(.zero) == CGPoint(x: 20, y: 10))
        #expect(m.original(CGPoint(x: 20, y: 10)) == .zero)
        #expect(
            m.rect(CGRect(x: 0, y: 0, width: 10, height: 10))
                == CGRect(x: 20, y: 10, width: 10, height: 10))
        #expect(m.renderedWidth == 125 && m.renderedHeight == 60)
    }

    @Test func seamGapsShiftByTheLeadingMargin() {
        let gap = map(bands: [20..<30]).seams(.horizontal)[0].gap
        #expect(gap.lowerBound == 30)
    }

    @Test func noMarginIsZero() {
        #expect(Margin.zero.isZero && !margin.isZero)
        #expect(map().withMargin(.zero).renderedWidth == 100)
    }
}
