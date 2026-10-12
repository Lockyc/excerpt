import CoreGraphics
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct EditDocumentTests {
    @Test func roundTrips() throws {
        let doc = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 10, upper: 90)])
        #expect(try EditDocument.decode(doc.encoded()) == doc)
    }

    @Test func unreadableJSONIsDamaged() {
        #expect(throws: EditDocumentError.damaged) { try EditDocument.decode(Data("{nope".utf8)) }
        let json = Data(#"{"version":2,"scale":"two"}"#.utf8)
        #expect(throws: EditDocumentError.damaged) { try EditDocument.decode(json) }
    }

    @Test func saltRoundTripsExactlyAndDiffersPerDocument() throws {
        let doc = EditDocument(scale: 2, salt: UInt64.max - 3)
        #expect(try EditDocument.decode(doc.encoded()).salt == UInt64.max - 3)
        #expect(EditDocument(scale: 2).salt != EditDocument(scale: 2).salt)
    }

    @Test func encodingIsStable() throws {
        let doc = EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 1, upper: 2)])
        #expect(try doc.encoded() == doc.encoded())
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        #expect(json.contains("\"version\":4") && !json.contains("border"))
    }

    @Test func rejectsANewerVersion() {
        let json = Data(#"{"version":5,"scale":2,"cuts":[]}"#.utf8)
        #expect(throws: EditDocumentError.unsupportedVersion(5)) { try EditDocument.decode(json) }
    }

    @Test func roundTripsCropAndEveryAnnotationKind() throws {
        let doc = EditDocument(
            scale: 2, cuts: [Cut(axis: .vertical, lower: 5, upper: 9)],
            crop: PixelRect(x: 4, y: 6, width: 100, height: 80),
            annotations: [
                Annotation(
                    id: 1, shape: .arrow(tail: CGPoint(x: 1, y: 2), head: CGPoint(x: 30, y: 40))),
                Annotation(
                    id: 2, shape: .rectangle(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
                    color: .blue, width: .thick),
                Annotation(
                    id: 3, shape: .text(origin: CGPoint(x: 5, y: 6), string: "Total ⋯\nline 2"),
                    color: .black, width: .thin),
                Annotation(
                    id: 4, shape: .highlight(rect: CGRect(x: 0, y: 0, width: 50, height: 10)),
                    color: .yellow),
                Annotation(id: 5, shape: .blur(rect: CGRect(x: 10, y: 10, width: 24, height: 24))),
                Annotation(
                    id: 6,
                    shape: .text(origin: CGPoint(x: 7, y: 8), string: "On", background: true),
                    color: .yellow),
                Annotation(id: 7, shape: .step(center: CGPoint(x: 40, y: 50)), color: .blue),
            ])
        #expect(try EditDocument.decode(doc.encoded()) == doc)
    }

    @Test func readsVersion3TextAsPlain() throws {
        let json = Data(
            #"""
            {"version":3,"scale":2,"cuts":[],"salt":1,"annotations":[
            {"id":1,"color":"red","width":"medium","shape":{"text":{"origin":[5,6],"string":"a"}}}]}
            """#.utf8)
        let doc = try EditDocument.decode(json)
        guard case .text(let origin, let string, let background) = doc.annotations.first?.shape
        else {
            Issue.record("not text")
            return
        }
        #expect(origin == CGPoint(x: 5, y: 6) && string == "a" && background == nil)
    }

    @Test func rejectsAStepOutOfRange() {
        let json = Data(
            #"""
            {"version":4,"scale":1,"cuts":[],"salt":1,"annotations":[
            {"id":1,"color":"red","width":"medium","shape":{"step":{"center":[2000000,0]}}}]}
            """#.utf8)
        #expect(throws: EditDocumentError.invalidGeometry) { try EditDocument.decode(json) }
    }

    @Test func readsAVersion1Document() throws {
        let json = Data(
            #"{"cuts":[{"axis":"horizontal","lower":10,"upper":90}],"scale":2,"version":1}"#.utf8)
        let doc = try EditDocument.decode(json)
        #expect(
            doc
                == EditDocument(
                    scale: 2, cuts: [Cut(axis: .horizontal, lower: 10, upper: 90)],
                    salt: doc.salt))
        // A missing salt is random, not a public seed, and persists once saved.
        #expect(try EditDocument.decode(json).salt != doc.salt)
        #expect(try EditDocument.decode(doc.encoded()).salt == doc.salt)
        #expect(String(decoding: try doc.encoded(), as: UTF8.self).contains("\"version\":4"))
    }

    @Test func borderRoundTripsAndReadsOffWhenAbsent() throws {
        let doc = EditDocument(scale: 2, border: Border(color: .blue, width: .thick))
        #expect(try EditDocument.decode(doc.encoded()).border == doc.border)
        #expect(!doc.isEmpty)
        let json = Data(#"{"version":2,"scale":2,"cuts":[]}"#.utf8)
        #expect(try EditDocument.decode(json).border == nil)
    }

    @Test func aBareTrueBorderReadsAsTheInitialOne() throws {
        let on = Data(#"{"version":3,"scale":2,"cuts":[],"border":true}"#.utf8)
        #expect(try EditDocument.decode(on).border == .initial)
        let off = Data(#"{"version":3,"scale":2,"cuts":[],"border":false}"#.utf8)
        #expect(try EditDocument.decode(off).border == nil)
    }

    @Test func emptinessCoversCropAndAnnotations() {
        #expect(EditDocument(scale: 1).isEmpty)
        #expect(!EditDocument(scale: 1, crop: PixelRect(x: 0, y: 0, width: 5, height: 5)).isEmpty)
        let note = Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 0, width: 5, height: 5)))
        #expect(!EditDocument(scale: 1, annotations: [note]).isEmpty)
    }

    @Test func nextAnnotationIDIsAboveEveryID() {
        let shape = Shape.blur(rect: .zero)
        #expect(EditDocument(scale: 1).nextAnnotationID == 1)
        let doc = EditDocument(
            scale: 1,
            annotations: [Annotation(id: 7, shape: shape), Annotation(id: 3, shape: shape)])
        #expect(doc.nextAnnotationID == 8)
    }
}

@Suite struct EditDocumentValidationTests {
    @Test func rejectsVersionZero() {
        let json = Data(#"{"version":0,"scale":2,"cuts":[]}"#.utf8)
        #expect(throws: EditDocumentError.unsupportedVersion(0)) { try EditDocument.decode(json) }
    }

    @Test func rejectsNonPositiveScale() {
        let json = Data(#"{"version":1,"scale":0,"cuts":[]}"#.utf8)
        #expect(throws: EditDocumentError.invalidScale(0)) { try EditDocument.decode(json) }
    }

    @Test func rejectsNonFiniteScale() {
        let json = Data(#"{"version":1,"scale":1e999,"cuts":[]}"#.utf8)
        #expect(throws: (any Error).self) { try EditDocument.decode(json) }
    }

    /// A master is a file anyone can hand excerpt: a scale past Retina would size a seam or a
    /// blur block past memory.
    @Test func rejectsAScaleOutsideTheRetinaRange() {
        for scale in ["0.5", "4", "1e10"] {
            let json = Data(#"{"version":2,"scale":\#(scale),"cuts":[]}"#.utf8)
            #expect(throws: EditDocumentError.invalidScale(Double(scale)!)) {
                try EditDocument.decode(json)
            }
        }
    }
}

@Suite struct PixelRectTests {
    @Test func clampsToTheImage() {
        let r = PixelRect(x: -10, y: 5, width: 50, height: 200)
        #expect(r.clamped(width: 30, height: 100) == PixelRect(x: 0, y: 5, width: 30, height: 95))
    }

    @Test func whollyOutsideIsNil() {
        #expect(PixelRect(x: 40, y: 0, width: 10, height: 10).clamped(width: 30, height: 30) == nil)
        #expect(PixelRect(x: 0, y: 0, width: 0, height: 10).clamped(width: 30, height: 30) == nil)
    }
}

@Suite struct EditDocumentGeometryTests {
    private func rejects(_ body: String) {
        let json = Data(#"{"version":2,"scale":2,"cuts":[],\#(body)}"#.utf8)
        #expect(throws: EditDocumentError.invalidGeometry) { try EditDocument.decode(json) }
    }

    private func note(_ id: Int, _ shape: String) -> String {
        #"{"id":\#(id),"shape":\#(shape),"color":"red","width":"thin"}"#
    }

    @Test func rejectsAnOverflowingCrop() {
        rejects(#""crop":{"x":9223372036854775807,"y":0,"width":10,"height":10}"#)
    }

    /// A cut bound near `Int.min` would overflow when the renderer offsets it by the crop.
    @Test func rejectsAHugeCutBound() {
        for (lower, upper) in [(Int.min, 5), (0, Int.max), (0, 1_000_001)] {
            let cut = #"{"axis":"horizontal","lower":\#(lower),"upper":\#(upper)}"#
            let json = Data(#"{"version":2,"scale":2,"cuts":[\#(cut)]}"#.utf8)
            #expect(throws: EditDocumentError.invalidGeometry) { try EditDocument.decode(json) }
        }
    }

    /// Every cut is a seam and a region to read: a crafted master's thousands are refused.
    @Test(.timeLimit(.minutes(1))) func rejectsMoreThanAThousandCutsOnAnAxis() throws {
        func document(horizontal: Int, vertical: Int) -> Data {
            let cuts =
                (0..<horizontal).map {
                    #"{"axis":"horizontal","lower":\#($0 * 3),"upper":\#($0 * 3 + 1)}"#
                }
                + (0..<vertical).map {
                    #"{"axis":"vertical","lower":\#($0 * 3),"upper":\#($0 * 3 + 1)}"#
                }
            return Data(#"{"version":2,"scale":2,"cuts":[\#(cuts.joined(separator: ","))]}"#.utf8)
        }
        let limit = EditDocument.maximumCutsPerAxis
        #expect(limit == 1_000)
        #expect(
            try EditDocument.decode(document(horizontal: limit, vertical: limit)).cuts.count == 2
                * limit)
        for (horizontal, vertical) in [(limit + 1, 0), (0, limit + 1)] {
            #expect(throws: EditDocumentError.invalidGeometry) {
                try EditDocument.decode(document(horizontal: horizontal, vertical: vertical))
            }
        }
    }

    /// Every blur is grouped against the others, so a crafted master's 100,000 are refused.
    @Test(.timeLimit(.minutes(1))) func rejectsMoreThanTenThousandAnnotations() throws {
        func document(_ count: Int) throws -> Data {
            try EditDocument(
                scale: 2,
                annotations: (0..<count).map {
                    Annotation(id: $0, shape: .blur(rect: CGRect(x: $0, y: 0, width: 4, height: 4)))
                }, salt: 7
            ).encoded()
        }
        let limit = EditDocument.maximumAnnotations
        #expect(limit == 10_000)
        #expect(try EditDocument.decode(try document(limit)).annotations.count == limit)
        #expect(throws: EditDocumentError.invalidGeometry) {
            try EditDocument.decode(try document(limit + 1))
        }
    }

    @Test func rejectsAnEmptyOrNegativeCrop() {
        rejects(#""crop":{"x":0,"y":0,"width":0,"height":10}"#)
        rejects(#""crop":{"x":0,"y":0,"width":10,"height":-5}"#)
    }

    @Test func rejectsHugeOrNonFiniteAnnotationGeometry() {
        let huge = #"{"blur":{"rect":[[0,0],[1e12,5]]}}"#
        rejects(#""annotations":[\#(note(1, huge))]"#)
        let negative = #"{"blur":{"rect":[[0,0],[-5,5]]}}"#
        rejects(#""annotations":[\#(note(1, negative))]"#)
        let arrow = #"{"arrow":{"tail":[0,0],"head":[1e999,0]}}"#
        let json = Data(
            #"{"version":2,"scale":2,"cuts":[],"annotations":[\#(note(1, arrow))]}"#.utf8)
        #expect(throws: (any Error).self) { try EditDocument.decode(json) }
    }

    @Test func rejectsDuplicateAndHugeIDs() {
        let shape = #"{"text":{"origin":[0,0],"string":"a"}}"#
        rejects(#""annotations":[\#(note(1, shape)),\#(note(1, shape))]"#)
        rejects(#""annotations":[\#(note(9_223_372_036_854_775_807, shape))]"#)
        rejects(#""annotations":[\#(note(-1, shape))]"#)
    }

    @Test func clampedSurvivesExtremeValues() {
        let r = PixelRect(x: Int.max, y: 0, width: 10, height: 10)
        #expect(r.clamped(width: 30, height: 30) == nil)
        #expect(
            PixelRect(x: Int.min, y: 0, width: Int.max, height: 5).clamped(width: 30, height: 30)
                == nil)
    }

    @Test func nextAnnotationIDDoesNotTrap() {
        let doc = EditDocument(
            scale: 1, annotations: [Annotation(id: Int.max, shape: .blur(rect: .zero))])
        #expect(doc.nextAnnotationID == Int.max)
    }
}
