import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct HitTestTests {
    let annotations = [
        Annotation(id: 1, shape: .rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100))),
        Annotation(
            id: 2, shape: .arrow(tail: CGPoint(x: 0, y: 200), head: CGPoint(x: 200, y: 200))),
        Annotation(id: 3, shape: .highlight(rect: CGRect(x: 50, y: 50, width: 100, height: 20))),
    ]

    let identity = RenderMap(
        crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
        rows: AxisMap(extent: 400, bands: [], gap: 20),
        columns: AxisMap(extent: 400, bands: [], gap: 20))
    let partlyHidden = RenderMap(
        crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
        rows: AxisMap(extent: 400, bands: [0..<50], gap: 20),
        columns: AxisMap(extent: 400, bands: [], gap: 20))
    let hidden = RenderMap(
        crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
        rows: AxisMap(extent: 400, bands: [0..<100], gap: 20),
        columns: AxisMap(extent: 400, bands: [], gap: 20))

    @Test func picksTheTopmost() {
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 60, y: 60), in: annotations, scale: 1, slop: 4, map: identity) == 3)
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 10, y: 10), in: annotations, scale: 1, slop: 4, map: identity) == 1)
    }

    @Test func arrowsHitAlongTheShaftOnly() {
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 100, y: 207), in: annotations, scale: 1, slop: 4, map: identity) == 2
        )
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 100, y: 230), in: annotations, scale: 1, slop: 4, map: identity)
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
        let p = CGPoint(x: 10, y: 10)
        #expect(HitTest.annotation(at: p, in: annotations, scale: 1, slop: 4, map: identity) == 1)
        #expect(HitTest.annotation(at: p, in: annotations, scale: 1, slop: 4, map: hidden) == nil)
    }

    @Test func theSlopBoundaryIsInclusive() {
        // Rectangle 1 spans 0...100 plus half its 10pt stroke: 105.
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 109, y: 20), in: annotations, scale: 1, slop: 4, map: identity)
                == 1)
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 109.5, y: 20), in: annotations, scale: 1, slop: 4, map: identity)
                == nil)
    }

    @Test func aPartlyHiddenAnnotationIsHitOnItsKeptPart() {
        // Rows 0..<50 are cut into a 20px gap; rectangle 1 shows from rendered y 20 to 70.
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 10, y: 60), in: annotations, scale: 1, slop: 0, map: partlyHidden)
                == 1)
    }

    @Test func anArrowAcrossASeamIsHitOnTheShaftItDraws() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 1200, height: 1200),
            rows: AxisMap(extent: 1200, bands: [100..<1000], gap: 18),
            columns: AxisMap(extent: 1200, bands: [], gap: 18))
        let arrow = Annotation(
            id: 1, shape: .arrow(tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 1000, y: 1100)))
        // Drawn from (0,0) to (1000,218): (400,87.2) lies on that shaft, above the seam.
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 400, y: 87.2), in: [arrow], scale: 1, slop: 6, map: map) == 1)
    }

    @Test func aStepOverASeamIsHitWhereItsCircleDraws() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 1400),
            rows: AxisMap(extent: 1400, bands: [120..<1120], gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
        let step = Annotation(id: 1, shape: .step(center: CGPoint(x: 200, y: 110)))
        // The circle drawn at (200,110) runs on over the gap below it.
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 200, y: 140), in: [step], scale: 2, slop: 0, map: map) == 1)
    }

    @Test func aCroppedRenderIsHitInRenderedPixels() {
        let map = RenderMap(
            crop: PixelRect(x: 100, y: 100, width: 300, height: 300),
            rows: AxisMap(extent: 300, bands: [], gap: 20),
            columns: AxisMap(extent: 300, bands: [], gap: 20))
        let box = Annotation(
            id: 1, shape: .highlight(rect: CGRect(x: 150, y: 150, width: 20, height: 20)))
        #expect(
            HitTest.annotation(at: CGPoint(x: 60, y: 60), in: [box], scale: 1, slop: 0, map: map)
                == 1)
        #expect(
            HitTest.annotation(
                at: CGPoint(x: 160, y: 160), in: [box], scale: 1, slop: 0, map: map) == nil)
    }

    @Test func crossingSeamsPreferTheNearerCentreLineThenTheVerticalOne() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 300, height: 400),
            rows: AxisMap(extent: 400, bands: [100..<200], gap: 20),
            columns: AxisMap(extent: 300, bands: [50..<80], gap: 20))
        // Row gap is 100..<120 (centre 110), column gap 50..<70 (centre 60).
        #expect(HitTest.seam(at: CGPoint(x: 62, y: 118), map: map, slop: 6)?.axis == .vertical)
        #expect(HitTest.seam(at: CGPoint(x: 68, y: 111), map: map, slop: 6)?.axis == .horizontal)
        #expect(HitTest.seam(at: CGPoint(x: 60, y: 110), map: map, slop: 6)?.axis == .vertical)
    }
}

@Suite struct GesturesTests {
    // Gridlines every 20 rows and every 60 columns.
    let sheet = PixelBuffer(Fixtures.sheet(width: 360, height: 400))

    @Test func theDominantDirectionPicksTheAxis() {
        let down = Gestures.cut(
            from: CGPoint(x: 10, y: 50), to: CGPoint(x: 30, y: 150), width: 360, height: 400,
            minimum: 8, snapping: nil,
            radius: 0)
        #expect(down == Cut(axis: .horizontal, lower: 50, upper: 150))
        let left = Gestures.cut(
            from: CGPoint(x: 200, y: 50), to: CGPoint(x: 90, y: 70), width: 360, height: 400,
            minimum: 8, snapping: nil,
            radius: 0)
        #expect(left == Cut(axis: .vertical, lower: 90, upper: 200))
    }

    @Test func aShortDragMakesNoCut() {
        #expect(
            Gestures.cut(
                from: CGPoint(x: 10, y: 50), to: CGPoint(x: 12, y: 55), width: 360, height: 400,
                minimum: 8, snapping: nil,
                radius: 0) == nil)
    }

    @Test func cutEdgesSnapToGridlines() {
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: 47), to: CGPoint(x: 10, y: 154), width: 360, height: 400,
            minimum: 8,
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

    @Test func adjustingKeepsTheCutACropHides() {
        // A crop at y 100 clips cut 50..<300 to the seam band 100..<300.
        let cuts = [Cut(axis: .horizontal, lower: 50, upper: 300)]
        let moved = Gestures.adjusting(
            cuts, axis: .horizontal, band: 100..<300, edge: .after, to: 350, extent: 400,
            snapping: nil, radius: 0)
        #expect(moved == [Cut(axis: .horizontal, lower: 50, upper: 350)])
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
        #expect(
            Shape.text(origin: .zero, string: "a", background: true).offset(dx: 2, dy: 3)
                == .text(origin: CGPoint(x: 2, y: 3), string: "a", background: true))
        #expect(
            Shape.step(center: CGPoint(x: 1, y: 1)).offset(dx: 2, dy: 3)
                == .step(center: CGPoint(x: 3, y: 4)))
    }

    @Test func dragsUpAndLeftStandardise() {
        let rect = Gestures.rect(from: CGPoint(x: 90, y: 80), to: CGPoint(x: 10, y: 20))
        #expect(rect == CGRect(x: 10, y: 20, width: 80, height: 60))
        let crop = Gestures.crop(
            from: CGPoint(x: 200, y: 300), to: CGPoint(x: 20, y: 40), width: 360, height: 400,
            minimum: 8, snapping: nil, radius: 0)
        #expect(crop == PixelRect(x: 20, y: 40, width: 180, height: 260))
        let up = Gestures.cut(
            from: CGPoint(x: 10, y: 150), to: CGPoint(x: 10, y: 50), width: 360, height: 400,
            minimum: 8, snapping: nil,
            radius: 0)
        #expect(up == Cut(axis: .horizontal, lower: 50, upper: 150))
    }

    @Test func draggingToTheFarEdgeKeepsTheEdge() {
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: 250), to: CGPoint(x: 10, y: 400), width: 360, height: 400,
            minimum: 8, snapping: sheet, radius: 12)
        #expect(cut == Cut(axis: .horizontal, lower: 240, upper: 400))
        let past = Gestures.cut(
            from: CGPoint(x: 10, y: 250), to: CGPoint(x: 10, y: 900), width: 360, height: 400,
            minimum: 8, snapping: sheet, radius: 12)
        #expect(past == cut)
        let handle = Gestures.adjusting(
            [Cut(axis: .horizontal, lower: 100, upper: 200)], axis: .horizontal, band: 100..<200,
            edge: .after, to: 400, extent: 400, snapping: sheet, radius: 12)
        #expect(handle.last == Cut(axis: .horizontal, lower: 100, upper: 400))
    }

    @Test func anEdgeBandStartsAtZero() {
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: -30), to: CGPoint(x: 10, y: 100), width: 360, height: 400,
            minimum: 8, snapping: sheet, radius: 12)
        #expect(cut == Cut(axis: .horizontal, lower: 0, upper: 100))
    }

    @Test func aDragThatRoundsToNothingMakesNoCut() {
        #expect(
            Gestures.cut(
                from: CGPoint(x: 10, y: 50.2), to: CGPoint(x: 10, y: 50.4), width: 360, height: 400,
                minimum: 0, snapping: nil, radius: 0) == nil)
    }

    @Test func anExactDiagonalRemovesRows() {
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 110), width: 360, height: 400,
            minimum: 8, snapping: nil, radius: 0)
        #expect(cut?.axis == .horizontal)
    }

    @Test func snappingThatWouldCollapseTheCutKeepsTheDraggedEdges() {
        // Both edges are within reach of the same gridline (y 40), so snapping would collapse
        // the cut; the dragged positions stand.
        let cut = Gestures.cut(
            from: CGPoint(x: 10, y: 38), to: CGPoint(x: 10, y: 46), width: 360, height: 400,
            minimum: 8, snapping: sheet, radius: 12)
        #expect(cut == Cut(axis: .horizontal, lower: 38, upper: 46))
    }

    @Test func theRadiusConvertsPointsToPixels() {
        #expect(GapSnapper.radius(scale: 2) == 24)
        #expect(GapSnapper.radius(scale: 1.25) == 15)
    }
}
