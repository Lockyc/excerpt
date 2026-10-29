import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct AnnotationGeometryTests {
    @Test func arrowHeadSitsAtTheHeadPointingAlongTheShaft() {
        let arrow = AnnotationGeometry.arrow(
            tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0), lineWidth: 10)
        #expect(arrow.head[0] == CGPoint(x: 100, y: 0))
        #expect(arrow.shaftEnd == CGPoint(x: 70, y: 0))
        #expect(arrow.head[1] == CGPoint(x: 70, y: 15))
        #expect(arrow.head[2] == CGPoint(x: 70, y: -15))
    }

    @Test func aShortArrowShrinksItsHead() {
        let arrow = AnnotationGeometry.arrow(
            tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 0, y: 12), lineWidth: 10)
        #expect(arrow.shaftEnd == CGPoint(x: 0, y: 0))
        #expect(arrow.head[1] == CGPoint(x: -6, y: 0))
    }

    @Test func aZeroLengthArrowDoesNotDivideByZero() {
        let p = CGPoint(x: 5, y: 5)
        let arrow = AnnotationGeometry.arrow(tail: p, head: p, lineWidth: 10)
        #expect(arrow.head == [p, p, p])
    }

    @Test func boundsIncludeTheStroke() {
        let rect = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 10, y: 10, width: 50, height: 20)),
            width: .medium)
        #expect(
            AnnotationGeometry.bounds(of: rect, scale: 2)
                == CGRect(x: 0, y: 0, width: 70, height: 40))
        let highlight = Annotation(
            id: 2, shape: .highlight(rect: CGRect(x: 60, y: 10, width: -50, height: 20)))
        #expect(
            AnnotationGeometry.bounds(of: highlight, scale: 2)
                == CGRect(x: 10, y: 10, width: 50, height: 20))
    }

    @Test func textGrowsWithLinesAndScale() {
        func size(_ s: String, _ width: StrokeWidth, scale: Double) -> CGSize {
            AnnotationGeometry.bounds(
                of: Annotation(id: 1, shape: .text(origin: .zero, string: s), width: width),
                scale: scale
            ).size
        }
        let one = size("Total", .medium, scale: 1)
        #expect(one.width > 0 && one.height > 30)
        #expect(abs(size("Total\nTotal", .medium, scale: 1).height - 2 * one.height) < 0.01)
        // The system font's optical sizing tracks large text tighter, so not exactly double.
        let doubled = size("Total", .medium, scale: 2).width / one.width
        #expect(doubled > 1.8 && doubled < 2.1)
        #expect(size("Total", .thick, scale: 1).width > one.width)
    }

    @Test func textIsLaidOutOncePerStringSizeAndColour() {
        let cache = TextCache()
        var made = 0
        func layout(_ string: String, _ size: Double, _ gray: Double) -> CGSize {
            cache.layout(string, pixelSize: size, color: CGColor(gray: gray, alpha: 1)) {
                made += 1
                return TextLayout(string, pixelSize: size, color: CGColor(gray: gray, alpha: 1))
            }.size
        }
        let first = layout("Total", 26, 0)
        #expect(layout("Total", 26, 0) == first)
        #expect(made == 1)
        _ = layout("Total", 26, 1)
        _ = layout("Total", 13, 0)
        _ = layout("Totals", 26, 0)
        #expect(made == 4)
    }

    @Test func theTextCacheEmptiesWhenFull() {
        let cache = TextCache()
        let black = CGColor(gray: 0, alpha: 1)
        for i in 0...TextCache.limit {
            _ = cache.layout(String(i), pixelSize: 10, color: black) {
                TextLayout(String(i), pixelSize: 10, color: black)
            }
        }
        #expect(cache.layoutCount == 1)
    }

    @Test func countsOnlyAnnotationsWhollyInsideACut() {
        // Rows 100..<200 removed.
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
            rows: AxisMap(extent: 400, bands: [100..<200], gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
        let inside = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 10, y: 120, width: 100, height: 40)),
            width: .thin)
        let straddling = Annotation(
            id: 2, shape: .rectangle(rect: CGRect(x: 10, y: 150, width: 100, height: 100)))
        let blurInside = Annotation(
            id: 3, shape: .blur(rect: CGRect(x: 0, y: 100, width: 400, height: 100)))
        let arrowInside = Annotation(
            id: 4, shape: .arrow(tail: CGPoint(x: 50, y: 140), head: CGPoint(x: 150, y: 160)))
        let arrowAcross = Annotation(
            id: 5, shape: .arrow(tail: CGPoint(x: 50, y: 50), head: CGPoint(x: 150, y: 160)))
        #expect(
            AnnotationGeometry.hiddenCount(
                [inside, straddling, blurInside, arrowInside, arrowAcross], map: map, scale: 1)
                == 3)
    }
}
