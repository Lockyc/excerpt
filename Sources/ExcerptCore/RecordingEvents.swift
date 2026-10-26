public enum ClickButton: String, Codable, Sendable {
    case left, right
}

/// One logged input. `time` is seconds of recorded time (pauses excluded); click `x`/`y` are
/// master pixels, top-left origin.
public enum RecordingEvent: Codable, Equatable, Sendable {
    case shortcut(time: Double, label: String)
    case click(time: Double, x: Double, y: Double, button: ClickButton)

    var time: Double {
        switch self {
        case .shortcut(let time, _), .click(let time, _, _, _): time
        }
    }
}

/// A recording's input log, stored in the master and drawn when the clip is rendered.
public struct RecordingEventLog: Codable, Equatable, Sendable {
    public static let version = 1

    public var version: Int
    /// Master pixels per point.
    public var scale: Double
    /// False when the recording ran without Input Monitoring, so no shortcut could be logged.
    public var shortcutsLogged: Bool
    public var events: [RecordingEvent]

    public init(version: Int, scale: Double, shortcutsLogged: Bool, events: [RecordingEvent]) {
        self.version = version
        self.scale = scale
        self.shortcutsLogged = shortcutsLogged
        self.events = events
    }
}

/// Which shortcut pill, if any, is on screen at a moment of the rendered clip.
public enum ShortcutTimeline {
    /// Seconds a pill stays after its latest press.
    public static let hold = 1.2

    /// The latest press at or before `t` while it is still held, with the length of the run of
    /// the same label it ends — each press within `hold` of the one before.
    public static func pill(at t: Double, in events: [RecordingEvent]) -> (
        label: String, count: Int
    )? {
        var shown: (label: String, count: Int, time: Double)?
        for case .shortcut(let time, let label) in events where time <= t {
            if let previous = shown, previous.label == label, time - previous.time < hold {
                shown = (label, previous.count + 1, time)
            } else {
                shown = (label, 1, time)
            }
        }
        guard let shown, t - shown.time < hold else { return nil }
        return (shown.label, shown.count)
    }
}

/// The expanding rings drawn at each click.
public enum ClickRings {
    /// Seconds a ring expands and fades over.
    public static let duration = 0.4

    /// The rings live at `t`; `progress` runs 0 to 1 over `duration`.
    public static func rings(at t: Double, in events: [RecordingEvent]) -> [(
        x: Double, y: Double, progress: Double, button: ClickButton
    )] {
        events.compactMap { event in
            guard case .click(let time, let x, let y, let button) = event,
                time <= t, t - time < duration
            else { return nil }
            return (x, y, (t - time) / duration, button)
        }
    }
}
