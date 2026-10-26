import Foundation
import Testing

@testable import ExcerptCore

@Suite struct RecordingEventsTests {
    @Test func pillHoldsAndCountsRepeats() {
        let events: [RecordingEvent] = [
            .shortcut(time: 1.0, label: "→"), .shortcut(time: 1.5, label: "→"),
            .shortcut(time: 2.0, label: "→"), .shortcut(time: 5.0, label: "⌘S"),
        ]
        #expect(ShortcutTimeline.pill(at: 0.5, in: events) == nil)
        let first = ShortcutTimeline.pill(at: 1.2, in: events)
        #expect(first?.label == "→" && first?.count == 1)
        let repeated = ShortcutTimeline.pill(at: 2.1, in: events)
        #expect(repeated?.label == "→" && repeated?.count == 3)
        #expect(ShortcutTimeline.pill(at: 3.3, in: events) == nil)  // 2.0 + 1.2 passed
        let later = ShortcutTimeline.pill(at: 5.1, in: events)
        #expect(later?.label == "⌘S" && later?.count == 1)
    }

    @Test func aGapLongerThanTheHoldStartsANewRun() {
        let events: [RecordingEvent] = [
            .shortcut(time: 1.0, label: "→"), .shortcut(time: 4.0, label: "→"),
        ]
        #expect(ShortcutTimeline.pill(at: 4.1, in: events)?.count == 1)
    }

    @Test func ringsRunForPointFourSeconds() {
        let events: [RecordingEvent] = [.click(time: 1, x: 10, y: 20, button: .left)]
        #expect(ClickRings.rings(at: 0.9, in: events).isEmpty)
        let ring = ClickRings.rings(at: 1.2, in: events).first!
        #expect(abs(ring.progress - 0.5) < 1e-9)
        #expect(ring.x == 10 && ring.y == 20 && ring.button == .left)
        #expect(ClickRings.rings(at: 1.41, in: events).isEmpty)
    }

    @Test func eventLogRoundTripsThroughJSON() throws {
        let log = RecordingEventLog(
            version: RecordingEventLog.version, scale: 2, shortcutsLogged: true,
            events: [
                .shortcut(time: 0.5, label: "⌘⇧K"),
                .click(time: 1.25, x: 120, y: 340.5, button: .right),
            ])
        let decoded = try JSONDecoder().decode(
            RecordingEventLog.self, from: JSONEncoder().encode(log))
        #expect(decoded == log)
    }
}
