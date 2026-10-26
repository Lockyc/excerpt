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
