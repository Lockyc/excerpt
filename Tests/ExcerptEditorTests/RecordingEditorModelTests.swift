import CoreGraphics
import ExcerptCore
import Testing

@testable import ExcerptEditor

@Suite struct RecordingEditorModelTests {
    func model(duration: Double = 10, shortcutsLogged: Bool = true) -> RecordingEditorModel {
        RecordingEditorModel(
            duration: duration, pixelSize: CGSize(width: 400, height: 300),
            log: RecordingEventLog(
                version: RecordingEventLog.version, scale: 2, shortcutsLogged: shortcutsLogged,
                events: []),
            edits: nil, defaultFormat: .gif)
    }

    @Test func trimClampsAndKeepsAMinimum() {
        var model = model()
        model.setTrim(-3...14)
        #expect(model.edits.trim == 0...10)
        model.setTrim(4...4.02)
        #expect(model.edits.trim.lowerBound == 4)
        #expect(model.edits.trim.upperBound == 4 + RecordingEditorModel.minimumTrim)
        // The end that moved gives way when the start is dragged onto it.
        model.setTrim(2...6)
        model.setTrim(5.98...6)
        #expect(model.edits.trim.upperBound == 6)
        #expect(model.edits.trim.lowerBound == 6 - RecordingEditorModel.minimumTrim)
        model.setTrim(9.99...12)
        #expect(model.edits.trim == (10 - RecordingEditorModel.minimumTrim)...10)
    }

    @Test func playheadStaysInsideTheTrim() {
        var model = model()
        model.playhead = 8
        model.setTrim(2...5)
        #expect(model.playhead == 5)
        model.playhead = 1
        #expect(model.playhead == 2)
        model.playhead = 3.5
        #expect(model.playhead == 3.5)
        model.undo()
        #expect(model.edits.trim == 0...10)
        #expect(model.playhead == 3.5)
    }

    @Test func blurSpanAndUndo() {
        var model = model()
        model.addBlur(CGRect(x: 350, y: 10, width: 100, height: 40))
        #expect(
            model.edits.blurs == [RecordingBlur(rect: CGRect(x: 350, y: 10, width: 50, height: 40))]
        )
        #expect(model.selection == 0)
        model.setSpan(-2...3, ofBlur: 0)
        #expect(model.edits.blurs[0].span == 0...3)
        model.setSpan(1...3, ofBlur: 0)
        #expect(model.edits.blurRects(at: 5).isEmpty)
        model.playhead = 6
        model.endSpan(ofBlur: 0)
        #expect(model.edits.blurs[0].span == 1...6)
        model.playhead = 7
        model.startSpan(ofBlur: 0)
        #expect(model.edits.blurs[0].span == 7...10)
        model.setSpan(nil, ofBlur: 0)
        #expect(model.edits.blurs[0].span == nil)
        model.undo()
        #expect(model.edits.blurs[0].span == 7...10)
        model.undo()
        model.undo()
        model.undo()
        model.undo()
        #expect(
            model.edits.blurs == [RecordingBlur(rect: CGRect(x: 350, y: 10, width: 50, height: 40))]
        )
        model.undo()
        #expect(model.edits.blurs.isEmpty)
        #expect(model.selection == nil)
        model.redo()
        #expect(model.edits.blurs.count == 1)
        model.removeBlur(0)
        #expect(model.edits.blurs.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func aBlurOutsideTheFrameIsNotAdded() {
        var model = model()
        model.addBlur(CGRect(x: 500, y: 10, width: 20, height: 20))
        #expect(model.edits.blurs.isEmpty)
        #expect(!model.canUndo)
    }

    @Test func shortcutsToggleDisabledWhenNotLogged() {
        #expect(model().shortcutsUnavailableReason == nil)
        #expect(
            model(shortcutsLogged: false).shortcutsUnavailableReason
                == "Input Monitoring was off for this recording")
    }

    @Test func freshModelHasNoUnsavedChanges() {
        var model = model()
        #expect(!model.hasUnsavedChanges)
        model.setShowsClicks(false)
        model.setFormat(.mp4)
        #expect(model.hasUnsavedChanges)
        model.markSaved()
        #expect(!model.hasUnsavedChanges)
        model.setShowsShortcuts(false)
        model.undo()
        #expect(!model.hasUnsavedChanges)
    }

    @Test func aContinuedTrimDragIsOneUndoStep() {
        var model = model()
        model.setTrim(1...10)
        model.setTrim(2...10, continuing: true)
        model.setTrim(3...10, continuing: true)
        model.undo()
        #expect(model.edits.trim == 0...10)
        #expect(!model.canUndo)
    }

    @Test func aSelectedBlurOffersItsSpan() {
        var model = model()
        #expect(model.itemOptions == nil)
        model.addBlur(CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(
            model.itemOptions == [
                .spanStart, .spanEnd, .wholeClip(enabled: false), .delete,
            ])
        model.setSpan(1...2, ofBlur: 0)
        #expect(model.itemOptions?.contains(.wholeClip(enabled: true)) == true)
    }
}
