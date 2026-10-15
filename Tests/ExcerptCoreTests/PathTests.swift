import CoreGraphics
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct PathTests {
    func path(_ points: [CGPoint], closed: Bool = false, fill: Bool = false) -> Annotation {
        Annotation(id: 1, shape: .path(points: points, closed: closed, fill: fill))
    }

    let zigzag = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 60), CGPoint(x: 40, y: 120)]

    @Test func aPathRoundTripsThroughTheMaster() throws {
        let doc = EditDocument(
            scale: 2, annotations: [path(zigzag, closed: true, fill: true)], salt: 3)
        #expect(try EditDocument.decode(doc.encoded()) == doc)
        let json = try JSONSerialization.jsonObject(with: doc.encoded()) as! [String: Any]
        #expect(json["version"] as? Int == 5)
    }

    @Test func aPathMovesAsAWhole() {
        #expect(
            Shape.path(points: zigzag, closed: true, fill: false).offset(dx: 5, dy: -10)
                == .path(
                    points: zigzag.map { CGPoint(x: $0.x + 5, y: $0.y - 10) }, closed: true,
                    fill: false))
    }

    @Test func aPathUnderTwoPointsOrOutOfRangeReadsAsDamaged() throws {
        // JSON can't carry a NaN, so out-of-range is the reachable bad coordinate.
        for points in [[CGPoint(x: 1, y: 1)], [CGPoint(x: 1, y: 1), CGPoint(x: 2e6, y: 0)]] {
            let doc = EditDocument(scale: 1, annotations: [path(points)], salt: 1)
            #expect(throws: EditDocumentError.invalidGeometry) {
                try EditDocument.decode(doc.encoded())
            }
        }
    }

    let open = RenderMap(
        crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
        rows: AxisMap(extent: 400, bands: [], gap: 36),
        columns: AxisMap(extent: 400, bands: [], gap: 36))

    @Test func boundsAreThePointsWithTheStroke() {
        let note = Annotation(
            id: 1, shape: .path(points: zigzag, closed: false, fill: false), width: .medium)
        #expect(
            AnnotationGeometry.bounds(of: note, scale: 1)
                == CGRect(x: 5, y: 5, width: 100, height: 120))
    }

    @Test func aClosedPathHasItsClosingSegment() {
        #expect(AnnotationGeometry.segments(zigzag, closed: false).count == 2)
        let closing = AnnotationGeometry.segments(zigzag, closed: true)
        #expect(closing.count == 3)
        #expect(closing[2].0 == zigzag[2] && closing[2].1 == zigzag[0])
        #expect(AnnotationGeometry.segments([zigzag[0], zigzag[1]], closed: true).count == 1)
    }

    @Test func aPathIsHitOnItsSegmentsAndInsideOnlyWhenFilled() {
        let square = [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300),
            CGPoint(x: 100, y: 300),
        ]
        func hit(_ p: CGPoint, closed: Bool, fill: Bool) -> Bool {
            HitTest.annotation(
                at: p, in: [path(square, closed: closed, fill: fill)], scale: 1, slop: 2,
                map: open) == 1
        }
        #expect(hit(CGPoint(x: 200, y: 103), closed: false, fill: false))  // on a side
        #expect(!hit(CGPoint(x: 103, y: 200), closed: false, fill: false))  // the missing side
        #expect(hit(CGPoint(x: 103, y: 200), closed: true, fill: false))  // closing side
        #expect(!hit(CGPoint(x: 200, y: 200), closed: true, fill: false))  // hollow inside
        #expect(hit(CGPoint(x: 200, y: 200), closed: true, fill: true))  // filled inside
        #expect(!hit(CGPoint(x: 200, y: 200), closed: false, fill: true))  // open ignores fill
    }

    @Test func aPathIsHiddenOnlyWhollyInsideOneBand() {
        let cut = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
            rows: AxisMap(extent: 400, bands: [100..<300], gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
        let inside = path([CGPoint(x: 10, y: 150), CGPoint(x: 200, y: 250)])
        let across = path([CGPoint(x: 10, y: 50), CGPoint(x: 200, y: 250)])
        #expect(!AnnotationGeometry.isDrawn(inside, map: cut, scale: 1))
        #expect(AnnotationGeometry.isDrawn(across, map: cut, scale: 1))
    }

    @Test func simplifyingKeepsCornersAndDropsJitter() {
        let jittery = (0...50).map { CGPoint(x: Double($0) * 4, y: $0 % 2 == 0 ? 0 : 1) }
        #expect(Gestures.simplify(jittery, tolerance: 2) == [jittery.first!, jittery.last!])
        let corner =
            (0...20).map { CGPoint(x: Double($0) * 5, y: 0) }
            + (1...20).map { CGPoint(x: 100, y: Double($0) * 5) }
        #expect(
            Gestures.simplify(corner, tolerance: 2)
                == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
        #expect(
            Gestures.simplify([zigzag[0], zigzag[1]], tolerance: 50) == [zigzag[0], zigzag[1]])
    }

    @Test func pathsGolden() throws {
        // An open thick route crossing a cut, a closed outline, a closed filled area, and an
        // open path with fill set, which draws no fill.
        let image = Fixtures.sheet(width: 600, height: 800)
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 400, upper: 500)],
            annotations: [
                Annotation(
                    id: 1,
                    shape: .path(
                        points: [
                            CGPoint(x: 40, y: 60), CGPoint(x: 200, y: 120),
                            CGPoint(x: 260, y: 560), CGPoint(x: 120, y: 700),
                        ], closed: false, fill: false),
                    color: .orange, width: .thick),
                Annotation(
                    id: 2,
                    shape: .path(
                        points: [
                            CGPoint(x: 340, y: 60), CGPoint(x: 560, y: 80),
                            CGPoint(x: 520, y: 300), CGPoint(x: 360, y: 260),
                        ], closed: true, fill: false),
                    color: .blue, width: .thin),
                Annotation(
                    id: 3,
                    shape: .path(
                        points: [
                            CGPoint(x: 340, y: 560), CGPoint(x: 560, y: 600),
                            CGPoint(x: 450, y: 760),
                        ], closed: true, fill: true),
                    color: .green, width: .medium),
                Annotation(
                    id: 4,
                    shape: .path(
                        points: [CGPoint(x: 60, y: 300), CGPoint(x: 160, y: 340)], closed: false,
                        fill: true),
                    color: .red, width: .medium),
            ],
            salt: 7)
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-paths")
    }

    @Test func tooManyPathPointsReadAsDamaged() throws {
        let line = (0..<(EditDocument.maximumPathPoints / 2 + 1)).map {
            CGPoint(x: Double($0 % 1000), y: Double($0 / 1000))
        }
        let doc = EditDocument(
            scale: 1,
            annotations: [
                Annotation(id: 1, shape: .path(points: line, closed: false, fill: false)),
                Annotation(id: 2, shape: .path(points: line, closed: false, fill: false)),
            ], salt: 1)
        #expect(doc.pathPointCount == 2 * line.count)
        #expect(throws: EditDocumentError.invalidGeometry) {
            try EditDocument.decode(doc.encoded())
        }
    }
}
