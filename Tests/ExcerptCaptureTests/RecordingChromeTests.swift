import CoreGraphics
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

extension RecordingChromeTests {
    @Test func aCancelledCountdownReturnsFalsePromptly() async {
        let chrome = RecordingChrome(area: CGRect(x: 100, y: 100, width: 400, height: 300))
        let task = Task { @MainActor in await chrome.countdown() }
        task.cancel()
        let started = ContinuousClock.now
        let finished = await task.value
        chrome.close()
        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
