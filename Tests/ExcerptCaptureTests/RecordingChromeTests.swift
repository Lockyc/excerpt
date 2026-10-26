import AppKit
import Testing

@testable import ExcerptCapture

@MainActor @Suite struct RecordingChromeTests {
    @Test func timeReadsMinutesAndSeconds() {
        #expect(RecordingChrome.timeText(recorded: 42.9, remaining: nil) == "0:42")
        #expect(RecordingChrome.timeText(recorded: 272, remaining: nil) == "4:32")
    }

    @Test func lastThirtySecondsShowTimeLeft() {
        #expect(RecordingChrome.timeText(recorded: 282, remaining: 17.6) == "4:42 · 0:18 left")
    }
}

/// What the chrome asked of the screen; nothing reaches it.
@MainActor final class StageLog {
    var activations = 0
    var shown: [(window: NSWindow, key: Bool)] = []
    var restored: [pid_t] = []

    var stage: RecordingChrome.Stage {
        RecordingChrome.Stage(
            activate: { self.activations += 1 },
            show: { self.shown.append(($0, $1)) },
            restore: { self.restored.append($0.processIdentifier) })
    }
}

extension RecordingChromeTests {
    static let area = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func aCancelledCountdownReturnsFalsePromptly() async {
        let log = StageLog()
        let chrome = RecordingChrome(area: Self.area, stage: log.stage)
        let task = Task { @MainActor in await chrome.countdown(restoring: nil) }
        task.cancel()
        let started = ContinuousClock.now
        let finished = await task.value
        chrome.close()
        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// The app named when the countdown began gets focus back, however the countdown ends.
    @Test func theCountdownGivesFocusBackToTheAppItWasGiven() async {
        let log = StageLog()
        let chrome = RecordingChrome(area: Self.area, stage: log.stage)
        let demonstrated = NSRunningApplication.current
        let task = Task { @MainActor in await chrome.countdown(restoring: demonstrated) }
        await Task.yield()
        chrome.close()
        #expect(await !task.value)
        #expect(log.activations == 1)
        #expect(log.shown.count == 1 && log.shown.first?.key == true)
        #expect(log.restored == [demonstrated.processIdentifier])
    }

    @Test func theRecordingChromeGoesUpThroughTheStage() {
        let log = StageLog()
        let chrome = RecordingChrome(area: Self.area, stage: log.stage)
        chrome.showRecording()
        chrome.close()
        #expect(log.shown.count == 2 && log.shown.allSatisfy { !$0.key })
        #expect(log.activations == 0)
    }
}
