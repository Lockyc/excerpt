import CoreGraphics
import ExcerptCore
import Testing

@testable import ExcerptEditor
@testable import ExcerptRecording

@Suite struct RecordingEditorModelTests {
    let tolerance = RecordingExporter.frameTolerance

    /// A clip of `duration` seconds with a frame stamped on each whole second unless
    /// `frameTimes` says otherwise.
    func model(
        duration: Double = 10, shortcutsLogged: Bool = true, frameTimes: [Double]? = nil
    ) -> RecordingEditorModel {
        var model = RecordingEditorModel(
            duration: duration, pixelSize: CGSize(width: 400, height: 300),
            log: RecordingEventLog(
                version: RecordingEventLog.version, scale: 2, shortcutsLogged: shortcutsLogged,
                events: []),
            edits: nil, defaultFormat: .gif)
        model.setFrameTimes(frameTimes ?? (0..<Int(duration)).map(Double.init))
        return model
    }

    /// The frame the exporter renders at `t`: the last stamped at or before it, within the
    /// tolerance, else the first.
    func exportedFrame(at t: Double, in times: [Double]) -> Int {
        times.lastIndex { $0 <= t + tolerance } ?? 0
    }

    @Test func aSpanSetAtThePlayheadCoversEverySampleOfItsFrame() throws {
        // A still screen sends no frames, so stamps are uneven.
        let times = [0, 0.4, 0.43, 2.0, 2.1, 3.7]
        for playhead in [0.0, 0.05, 0.41, 0.45, 1.99, 2.05, 3.8, 4.0] {
            var model = model(duration: 4, frameTimes: times)
            model.addBlur(CGRect(x: 0, y: 0, width: 50, height: 50))
            model.playhead = playhead
            model.startSpan(ofBlur: 0)
            model.endSpan(ofBlur: 0)
            let span = try #require(model.edits.blurs[0].span)
            #expect(span.lowerBound < span.upperBound)
            let shown = exportedFrame(at: model.playhead, in: times)
            for fps in [10, 15, 30] {
                for sample in RecordingExporter.samples(over: 0...4, fps: fps)
                where exportedFrame(at: sample.time, in: times) == shown {
                    #expect(span.contains(sample.time), "\(sample.time) s at \(playhead) s")
                }
            }
        }
    }

    /// The frame the preview decodes at its time: what a zero-tolerance decoder shows there.
    func decodedFrame(at t: Double, in times: [Double]) -> Int {
        times.lastIndex { $0 <= t } ?? 0
    }

    @Test func thePreviewShowsTheFrameSpansAreSetFrom() {
        let times = [0, 0.4, 0.43, 2.0, 2.1, 3.7]
        // Just either side of each stamp, inside and outside the tolerance, and mid-frame.
        let offsets = [-0.0009, -0.0006, -0.0004, -0.0001, 0, 0.0001, 0.0009, 0.01]
        for stamp in times {
            for offset in offsets where stamp + offset >= 0 && stamp + offset <= 4 {
                var model = model(duration: 4, frameTimes: times)
                model.playhead = stamp + offset
                let k = exportedFrame(at: model.playhead, in: times)
                #expect(model.shownFrameIndex == k)
                #expect(
                    decodedFrame(at: model.previewFrameTime, in: times) == k,
                    "playhead \(model.playhead) s")
                // Far enough from the next stamp that rounding to the decoder's clock can't
                // cross it.
                let next = k + 1 < times.count ? times[k + 1] : 4
                #expect(model.previewFrameTime > times[k] + 0.001)
                #expect(model.previewFrameTime < next - 0.001)
            }
        }
    }

    @Test func aSpanStartedAtTheTrimEndStillCoversAFrame() throws {
        var model = model()
        model.setTrim(2...5)
        model.addBlur(CGRect(x: 0, y: 0, width: 50, height: 50))
        model.playhead = 5
        model.startSpan(ofBlur: 0)
        let span = try #require(model.edits.blurs[0].span)
        #expect(span.lowerBound < span.upperBound)
        #expect(span.contains(5))

        var last = self.model()
        last.addBlur(CGRect(x: 0, y: 0, width: 50, height: 50))
        last.playhead = 10
        last.startSpan(ofBlur: 0)
        let lastSpan = try #require(last.edits.blurs[0].span)
        #expect(lastSpan.lowerBound <= 9 - tolerance && lastSpan.lowerBound > 9 - 2 * tolerance)
        #expect(lastSpan.upperBound == 10)
    }

    @Test func spansWaitForTheFrameTimes() {
        var model = RecordingEditorModel(
            duration: 10, pixelSize: CGSize(width: 400, height: 300),
            log: RecordingEventLog(
                version: RecordingEventLog.version, scale: 2, shortcutsLogged: true, events: []),
            edits: nil, defaultFormat: .gif)
        model.addBlur(CGRect(x: 0, y: 0, width: 50, height: 50))
        model.playhead = 4
        model.startSpan(ofBlur: 0)
        #expect(model.edits.blurs[0].span == nil)
        let reading = "Reading the recording's frames…"
        #expect(model.itemOptions?.first == .spanStart(unavailable: reading))
        model.setFrameTimes(nil)
        #expect(
            model.itemOptions?.first
                == .spanStart(unavailable: "The recording's frames couldn't be read"))
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

    @Test func blurSpanAndUndo() throws {
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
        // Frames are stamped on whole seconds: a span set at the playhead covers its frame.
        model.playhead = 6.5
        model.endSpan(ofBlur: 0)
        let ended = try #require(model.edits.blurs[0].span)
        #expect(ended.lowerBound == 1)
        #expect(ended.upperBound >= 7 - tolerance && ended.upperBound < 7 - tolerance / 2)
        model.playhead = 7.5
        model.startSpan(ofBlur: 0)
        let started = try #require(model.edits.blurs[0].span)
        #expect(started.lowerBound <= 7 - tolerance && started.lowerBound > 7 - 2 * tolerance)
        #expect(started.upperBound == 10)
        model.setSpan(nil, ofBlur: 0)
        #expect(model.edits.blurs[0].span == nil)
        model.undo()
        #expect(model.edits.blurs[0].span == started)
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
                .spanStart(unavailable: nil), .spanEnd(unavailable: nil),
                .wholeClip(enabled: false), .delete,
            ])
        model.setSpan(1...2, ofBlur: 0)
        #expect(model.itemOptions?.contains(.wholeClip(enabled: true)) == true)
    }
}

@MainActor @Suite struct RecordingFrameViewTests {
    @Test func blurRectsMapBetweenTheViewAndMasterPixels() {
        let view = RecordingFrameView(pixelSize: CGSize(width: 800, height: 600))
        // A 400 × 300 area inside the gutter: half a point per master pixel, top-left origin.
        view.frame = CGRect(x: 0, y: 0, width: 424, height: 324)
        let pixels = CGRect(x: 100, y: 50, width: 200, height: 100)
        #expect(view.viewRect(pixels) == CGRect(x: 62, y: 37, width: 100, height: 50))
        #expect(view.pixelRect(view.viewRect(pixels)) == pixels)
    }
}
