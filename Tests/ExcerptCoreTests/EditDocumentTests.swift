import Foundation
import Testing

@testable import ExcerptCore

@Suite struct EditDocumentTests {
    @Test func roundTrips() throws {
        let doc = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 10, upper: 90)])
        #expect(try EditDocument.decode(doc.encoded()) == doc)
    }

    @Test func encodingIsStable() throws {
        let doc = EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 1, upper: 2)])
        #expect(try doc.encoded() == doc.encoded())
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        #expect(json.contains("\"version\":1"))
    }

    @Test func rejectsANewerVersion() {
        let json = Data(#"{"version":2,"scale":2,"cuts":[]}"#.utf8)
        #expect(throws: EditDocumentError.unsupportedVersion(2)) { try EditDocument.decode(json) }
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
}
