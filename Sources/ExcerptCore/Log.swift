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

    /// `error` as a log line: its type or domain and code, its message, its other userInfo,
    /// then each underlying error the same way, so a framework failure names its root cause
    /// rather than only the sentence an alert shows.
    public static func describe(_ error: Error) -> String {
        describe(error, depth: 0)
    }

    private static func describe(_ error: Error, depth: Int) -> String {
        let ns = error as NSError
        // A Swift error's bridged domain and code are its type and case index: its own
        // description names the case and its values instead.
        var line =
            type(of: error) is NSError.Type
            ? "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            : "\(String(reflecting: type(of: error))).\(error): \(ns.localizedDescription)"
        let shown: Set<String> = [
            NSLocalizedDescriptionKey, NSUnderlyingErrorKey, NSMultipleUnderlyingErrorsKey,
        ]
        let extra = ns.userInfo.filter { !shown.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.sorted()
        if !extra.isEmpty { line += " [\(extra.joined(separator: ", "))]" }
        guard depth < 8 else { return line }
        var underlying = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] ?? []
        if let single = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            underlying.insert(single, at: 0)
        }
        for cause in underlying { line += " ← " + describe(cause, depth: depth + 1) }
        return line
    }
}
