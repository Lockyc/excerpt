import CoreGraphics
import Foundation
import Testing

@testable import ExcerptCore

struct RecordingEditsTests {
    @Test func freshCoversTheWholeClip() {
        let edits = RecordingEdits.fresh(duration: 12.5, format: .gif)
        #expect(edits.version == RecordingEdits.version)
        #expect(edits.trim == 0...12.5)
        #expect(edits.blurs.isEmpty)
        #expect(edits.showsShortcuts)
        #expect(edits.showsClicks)
        #expect(edits.format == .gif)
    }

    @Test func blurRectsHonourSpans() {
        var edits = RecordingEdits.fresh(duration: 10, format: .mp4)
        let timed = CGRect(x: 1, y: 2, width: 30, height: 40)
        let always = CGRect(x: 5, y: 6, width: 70, height: 80)
        edits.blurs = [
            RecordingBlur(rect: timed, span: 2...4),
            RecordingBlur(rect: always, span: nil),
        ]
        #expect(edits.blurRects(at: 3) == [timed, always])
        #expect(edits.blurRects(at: 5) == [always])
    }

    @Test func roundTripsThroughJSON() throws {
        var edits = RecordingEdits.fresh(duration: 8, format: .mp4)
        edits.trim = 1...6.5
        edits.showsClicks = false
        edits.blurs = [
            RecordingBlur(rect: CGRect(x: 1, y: 2, width: 3, height: 4), span: 0.5...2),
            RecordingBlur(rect: CGRect(x: 9, y: 8, width: 7, height: 6), span: nil),
        ]
        let data = try JSONEncoder().encode(edits)
        #expect(try RecordingEdits.decode(data) == edits)
    }

    @Test func rejectsAFutureVersion() throws {
        var edits = RecordingEdits.fresh(duration: 5, format: .gif)
        edits.version = RecordingEdits.version + 1
        let data = try JSONEncoder().encode(edits)
        #expect(throws: EditDocumentError.unsupportedVersion(RecordingEdits.version + 1)) {
            try RecordingEdits.decode(data)
        }
    }

    @Test func rejectsTooManyBlurs() throws {
        var edits = RecordingEdits.fresh(duration: 5, format: .gif)
        let blur = RecordingBlur(rect: CGRect(x: 0, y: 0, width: 1, height: 1), span: nil)
        edits.blurs = Array(repeating: blur, count: EditDocument.maximumAnnotations + 1)
        let data = try JSONEncoder().encode(edits)
        #expect(throws: EditDocumentError.invalidGeometry) { try RecordingEdits.decode(data) }
    }

    @Test func rejectsAnEmptyOrNonFiniteTrimAndNonFiniteBlurs() throws {
        var empty = RecordingEdits.fresh(duration: 5, format: .gif)
        empty.trim = 2...2
        var infinite = RecordingEdits.fresh(duration: 5, format: .gif)
        infinite.trim = 0...Double.infinity
        var blurred = RecordingEdits.fresh(duration: 5, format: .gif)
        blurred.blurs = [
            RecordingBlur(rect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), span: nil)
        ]
        for edits in [empty, infinite, blurred] {
            #expect(throws: EditDocumentError.invalidGeometry) { try edits.validate() }
        }
    }
}
