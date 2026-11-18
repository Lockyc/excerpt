import Testing

@testable import ExcerptCore

/// The modes a test presses; `record` also stops a recording, and `selector` is the mode bar.
enum Mode: Equatable {
    case area, window, record, selector
}

/// A lifecycle whose recordings and waiting quits are numbered.
typealias Lifecycle = CaptureLifecycle<Mode, Int, Int>

func lifecycle() -> Lifecycle { Lifecycle(record: .record, selector: .selector) }

extension Lifecycle.Dispatch {
    var starts: Bool { if case .start = self { true } else { false } }
    var switches: Bool { if case .switchMode = self { true } else { false } }
    var ignores: Bool { if case .ignore = self { true } else { false } }
    var stops: Int? { if case .stopRecording(let recording) = self { recording } else { nil } }
}

@Suite struct CaptureLifecycleTests {
    /// 811a3c8: the Record hotkey stops a recording, its save starts, and a screenshot hotkey
    /// pressed while that save renders starts a capture.
    @Test func aHotkeyStartsACaptureWhileAStoppedRecordingSaves() {
        var life = lifecycle()
        #expect(life.hotkey(.record).starts)
        life.recordingStarted(1)
        #expect(life.hotkey(.record).stops == 1)
        let ended = life.recordingEnded(kept: true)
        #expect(ended.save != nil)
        life.captureEnded()
        #expect(life.isRecordingOrSaving)
        #expect(life.hotkey(.area).starts)
    }

    /// 8cfccc9: a quit mid-recording stops the recording and answers only once it is kept and
    /// its save has ended.
    @Test func aQuitMidRecordingStopsItAndWaitsForItsSave() {
        var life = lifecycle()
        _ = life.hotkey(.record)
        life.recordingStarted(1)
        let quit = life.quitRequested(7)
        #expect(quit.stop == 1)
        #expect(quit.replies.isEmpty)
        let ended = life.recordingEnded(kept: true)
        #expect(ended.replies.isEmpty)
        life.captureEnded()
        #expect(life.saveEnded(ended.save!) == [7])
    }

    @Test func aQuitWithNothingRecordingOrSavingAnswersAtOnce() {
        var life = lifecycle()
        let quit = life.quitRequested(1)
        #expect(quit.stop == nil)
        #expect(quit.replies == [1])
    }

    /// A recording that ends with nothing kept starts no save, so the waiting quit answers.
    @Test func aDiscardedRecordingAnswersTheQuitWithNoSave() {
        var life = lifecycle()
        _ = life.hotkey(.record)
        life.recordingStarted(1)
        _ = life.quitRequested(1)
        let ended = life.recordingEnded(kept: false)
        #expect(ended.save == nil)
        #expect(ended.replies == [1])
    }

    /// Mid-selection, another mode's hotkey switches to it; the same mode's, the mode bar's and
    /// any press with no selection up are ignored.
    @Test func aHotkeyMidSelectionSwitchesOnlyToAnotherMode() {
        var life = lifecycle()
        #expect(life.hotkey(.area).starts)
        #expect(life.hotkey(.window).ignores)
        life.selectionBegan(.area)
        #expect(life.hotkey(.area).ignores)
        #expect(life.hotkey(.selector).ignores)
        #expect(life.switchedTo == nil)
        #expect(life.hotkey(.window).switches)
        #expect(life.switchedTo == .window)
    }
}
