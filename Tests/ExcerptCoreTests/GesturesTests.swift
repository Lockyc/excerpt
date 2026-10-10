import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct HitTestTests {
    let annotations = [
        Annotation(id: 1, shape: .rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100))),
        Annotation(
            id: 2, shape: .arrow(tail: CGPoint(x: 0, y: 200), head: CGPoint(x: 200, y: 200))),
        Annotation(id: 3, shape: .highlight(rect: CGRect(x: 50, y: 50, width: 100, height: 20))),
    ]

    @Test func picksTheTopmost() {
        #expect(
            HitTest.annotation(at: CGPoint(x: 60, y: 60), in: annotations, scale: 1, slop: 4) == 3)
        #expect(
            HitTest.annotation(at: CGPoint(x: 10, y: 10), in: annotations, scale: 1, slop: 4) == 1)
    }

    @Test func arrowsHitAlongTheShaftOnly() {
        #expect(
            HitTest.annotation(at: CGPoint(x: 100, y: 207), in: annotations, scale: 1, slop: 4) == 2
        )
        #expect(
            HitTest.annotation(at: CGPoint(x: 100, y: 230), in: annotations, scale: 1, slop: 4)
                == nil)
    }

    @Test func seamsHitNearTheirGap() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 300, height: 400),
            rows: AxisMap(extent: 400, bands: [100..<200], gap: 20),
            columns: AxisMap(extent: 300, bands: [50..<80], gap: 20))
        #expect(HitTest.seam(at: CGPoint(x: 200, y: 110), map: map, slop: 6)?.band == 100..<200)
        #expect(HitTest.seam(at: CGPoint(x: 200, y: 124), map: map, slop: 6)?.axis == .horizontal)
        #expect(HitTest.seam(at: CGPoint(x: 60, y: 250), map: map, slop: 6)?.axis == .vertical)
        #expect(HitTest.seam(at: CGPoint(x: 200, y: 250), map: map, slop: 6) == nil)
    }

    @Test func anAnnotationTheCutHidesCannotBeHit() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 300, height: 400),
            rows: AxisMap(extent: 400, bands: [0..<100], gap: 20),
            columns: AxisMap(extent: 300, bands: [], gap: 20))
        let p = CGPoint(x: 10, y: 10)
        #expect(HitTest.annotation(at: p, in: annotations, scale: 1, slop: 4) == 1)
        #expect(HitTest.annotation(at: p, in: annotations, scale: 1, slop: 4, map: map) == nil)
    }
}

@Suite struct GesturesTests {
    // Gridlines every 20 rows and every 60 columns.
    let sheet = PixelBuffer(Fixtures.sheet(width: 360, height: 400))

    @Test func theDominantDirectionPicksTheAxis() {
        let down = Gestures.cut(
            from: CGPoint(x: 10, y: 50), to: CGPoint(x: 30, y: 150), minimum: 8, snapping: nil,
            radius: 0)
        #expect(down == Cut(axis: .horizontal, lower: 50, upper: 150))
        let left = Gestures.cut(
            from: CGPoint(x: 200, y: 50), to: CGPoint(x: 90, y: 70), minimum: 8, snapping: nil,
            radius: 0)
        #expect(left == Cut(axis: .vertical, lower: 90, upper: 200))
    }

    @Test func aShortDragMakesNoCut() {
        #expect(
            Gestures.cut(
                from: CGPoint(x: 10, y: 50), to: CGPoint(x: 12, y: 55), minimum: 8, snapping: nil,
                radius: 0) == nil)
    }

    @Test func cutEdgesSnapToGridlines() {
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: 47), to: CGPoint(x: 10, y: 154), minimum: 8,
            snapping: sheet, radius: 12)
        #expect(cut == Cut(axis: .horizontal, lower: 40, upper: 160))
    }

    @Test func adjustingMovesOneEdgeAndMergesTheBandsCuts() {
        let cuts = [
            Cut(axis: .horizontal, lower: 100, upper: 150),
            Cut(axis: .horizontal, lower: 140, upper: 200),
            Cut(axis: .horizontal, lower: 300, upper: 350),
            Cut(axis: .vertical, lower: 100, upper: 150),
        ]
        let moved = Gestures.adjusting(
            cuts, axis: .horizontal, band: 100..<200, edge: .after, to: 240, extent: 400,
            snapping: nil, radius: 0)
        #expect(
            moved == [
                Cut(axis: .horizontal, lower: 300, upper: 350),
                Cut(axis: .vertical, lower: 100, upper: 150),
                Cut(axis: .horizontal, lower: 100, upper: 240),
            ])
    }

    @Test func anEdgeStopsShortOfTheOtherAndTheImage() {
        let cuts = [Cut(axis: .horizontal, lower: 100, upper: 200)]
        let past = Gestures.adjusting(
            cuts, axis: .horizontal, band: 100..<200, edge: .before, to: 260, extent: 400,
            snapping: nil, radius: 0)
        #expect(past == [Cut(axis: .horizontal, lower: 199, upper: 200)])
        let off = Gestures.adjusting(
            cuts, axis: .horizontal, band: 100..<200, edge: .after, to: 900, extent: 400,
            snapping: nil, radius: 0)
        #expect(off == [Cut(axis: .horizontal, lower: 100, upper: 400)])
    }

    @Test func adjustedEdgesSnap() {
        let cuts = [Cut(axis: .horizontal, lower: 100, upper: 200)]
        let snapped = Gestures.adjusting(
            cuts, axis: .horizontal, band: 100..<200, edge: .after, to: 236, extent: 400,
            snapping: sheet, radius: 12)
        #expect(snapped == [Cut(axis: .horizontal, lower: 100, upper: 240)])
    }

    @Test func removingDropsEveryCutOfTheBand() {
        let cuts = [
            Cut(axis: .horizontal, lower: 100, upper: 150),
            Cut(axis: .horizontal, lower: 150, upper: 200),
            Cut(axis: .vertical, lower: 120, upper: 130),
        ]
        #expect(
            Gestures.removing(cuts, axis: .horizontal, band: 100..<200)
                == [Cut(axis: .vertical, lower: 120, upper: 130)])
    }

    @Test func cropClampsSnapsAndRejectsSlivers() {
        let crop = Gestures.crop(
            from: CGPoint(x: 400, y: -30), to: CGPoint(x: 64, y: 236), width: 360, height: 400,
            minimum: 8, snapping: sheet, radius: 12)
        #expect(crop == PixelRect(x: 60, y: 0, width: 300, height: 240))
        #expect(
            Gestures.crop(
                from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 200), width: 360, height: 400,
                minimum: 8, snapping: nil, radius: 0) == nil)
    }

    @Test func movingAShapeMovesEveryPoint() {
        #expect(
            Shape.arrow(tail: CGPoint(x: 1, y: 2), head: CGPoint(x: 3, y: 4)).offset(dx: 10, dy: -1)
                == .arrow(tail: CGPoint(x: 11, y: 1), head: CGPoint(x: 13, y: 3)))
        #expect(
            Shape.text(origin: .zero, string: "a").offset(dx: 2, dy: 3)
                == .text(origin: CGPoint(x: 2, y: 3), string: "a"))
    }

    @Test func dragsUpAndLeftStandardise() {
        let rect = Gestures.rect(from: CGPoint(x: 90, y: 80), to: CGPoint(x: 10, y: 20))
        #expect(rect == CGRect(x: 10, y: 20, width: 80, height: 60))
        let crop = Gestures.crop(
            from: CGPoint(x: 200, y: 300), to: CGPoint(x: 20, y: 40), width: 360, height: 400,
            minimum: 8, snapping: nil, radius: 0)
        #expect(crop == PixelRect(x: 20, y: 40, width: 180, height: 260))
        let up = Gestures.cut(
            from: CGPoint(x: 10, y: 150), to: CGPoint(x: 10, y: 50), minimum: 8, snapping: nil,
            radius: 0)
        #expect(up == Cut(axis: .horizontal, lower: 50, upper: 150))
    }
}
