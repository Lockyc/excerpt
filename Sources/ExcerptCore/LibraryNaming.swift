import Foundation

/// File names in the screenshot library: `<prefix> 2026-10-10 at 09.43.29.png` for the primary,
/// with ` original` before `.png` for its master.
public struct LibraryNaming: Sendable {
    public static let originalSuffix = " original.png"

    public var prefix: String
    public var timeZone: TimeZone

    public init(prefix: String = "Excerpt", timeZone: TimeZone = .current) {
        self.prefix = prefix
        self.timeZone = timeZone
    }

    /// The name without extension or collision counter.
    public func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    public static func originalName(forPrimary primary: String) -> String {
        String(primary.dropLast(".png".count)) + originalSuffix
    }

    /// nil when `original` is not a master's name.
    public static func primaryName(forOriginal original: String) -> String? {
        guard original.hasSuffix(originalSuffix) else { return nil }
        return String(original.dropLast(originalSuffix.count)) + ".png"
    }
}
