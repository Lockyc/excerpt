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
