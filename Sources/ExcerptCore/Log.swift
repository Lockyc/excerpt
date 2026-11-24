import Foundation
import os

/// Excerpt's unified-log channels, one category per concern under the app's bundle identifier:
/// `log stream --level info --predicate 'subsystem == "<id>"'` follows them. A failure the app
/// recovers from without telling the user is logged here, so it leaves a trace.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "excerpt"
    /// A capture's stages, with their time since its hotkey, and its recovered failures.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Every failure an alert shows the user.
    public static let alert = Logger(subsystem: subsystem, category: "alert")
    /// The recording editor and a recording's poster frame.
    public static let recording = Logger(subsystem: subsystem, category: "recording")
    /// One interval per window still, for Instruments' Points of Interest-style signpost track.
    public static let stills = OSSignposter(subsystem: subsystem, category: "stills")
}
