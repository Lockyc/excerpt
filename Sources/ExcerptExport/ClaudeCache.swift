import Foundation

/// A cache failure, carrying the path it happened at.
public struct ClaudeCacheError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let path: String
    public let reason: String

    public var description: String { "\(path): \(reason)" }

    /// Just the reason: callers that name the path themselves (the alert) don't repeat it.
    public var errorDescription: String? { reason }
}

/// Where For Claude bundles live: scratch under the user's caches, one folder per capture,
/// each removed once it is `maximumAge` old.
public struct ClaudeCache: Sendable {
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// What a prune did: the entries it removed, and the expired ones it could not.
    public struct Pruned: Sendable {
        public var removed: [URL] = []
        public var failed: [(url: URL, error: ClaudeCacheError)] = []
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Caches/excerpt/claude`.
    public static var standard: ClaudeCache {
        ClaudeCache(
            root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("excerpt/claude", isDirectory: true))
    }

    /// The folder name for the capture whose primary is at `primary`: its name, readable, then
    /// an 8-hex-digit hash of the primary's resolved path, so captures with the same name in
    /// different folders never share a bundle, and every route to one file shares one. In the
    /// name, anything but letters, digits, `.`, `_` and `-` becomes `-`, and a leading `.` too,
    /// so `Excerpt 2026-10-10 at 09.43.29` reads `Excerpt-2026-10-10-at-09.43.29-<hash>`; it is
    /// cut to 91 characters, and `capture` stands in for an empty one. The result never starts
    /// with `.`: the dot-names under the root are the staging folders alone.
    public static func folderName(for primary: URL) -> String {
        let name = primary.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = name.unicodeScalars.enumerated().map { index, scalar in
            allowed.contains(scalar) && !(index == 0 && scalar == ".") ? scalar : "-"
        }
        let clean = String(String.UnicodeScalarView(mapped))
        let base = clean.isEmpty ? "capture" : String(clean.prefix(91))
        let path = primary.absoluteURL.standardizedFileURL.resolvingSymlinksInPath().path
        return "\(base)-\(stableHash(path))"
    }

    /// 8 hex digits of FNV-1a over the UTF-8 bytes, folded from 64 bits: stable across runs
    /// and machines, unlike `Hasher`.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let folded = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
        let hex = String(folded, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The folder for the capture whose primary is at `primary`: a direct child of the root,
    /// whatever its name.
    public func folder(for primary: URL) -> URL {
        root.appendingPathComponent(Self.folderName(for: primary), isDirectory: true)
    }

    /// Creates the root, and any missing parents, with user-only permissions (0700); a root that
    /// already exists keeps the permissions it has.
    public func ensureRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw ClaudeCacheError(path: root.path, reason: error.localizedDescription)
        }
    }

    /// The entries last modified `maximumAge` or more before `now`; a future-dated entry never
    /// expires.
    public static func expired(
        _ entries: [(url: URL, modified: Date)], now: Date, maximumAge: TimeInterval = maximumAge
    ) -> [URL] {
        entries.filter { now.timeIntervalSince($0.modified) >= maximumAge }.map(\.url)
    }

    /// Removes every expired entry of the cache, trying each one: an entry that cannot be
    /// removed (or dated) is reported in `failed` and never stops the rest. A cache not yet made
    /// has none. Throws only when the cache folder itself cannot be listed.
    @discardableResult
    public func prune(now: Date) throws -> Pruned {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return Pruned() }
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw ClaudeCacheError(path: root.path, reason: error.localizedDescription)
        }
        var result = Pruned()
        var dated: [(url: URL, modified: Date)] = []
        for url in entries {
            do {
                guard
                    let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                else { throw ClaudeCacheError(path: url.path, reason: "no modification date") }
                dated.append((url, modified))
            } catch let error as ClaudeCacheError {
                result.failed.append((url, error))
            } catch {
                result.failed.append(
                    (url, ClaudeCacheError(path: url.path, reason: error.localizedDescription)))
            }
        }
        for url in Self.expired(dated, now: now) {
            do {
                try manager.removeItem(at: url)
                result.removed.append(url)
            } catch {
                result.failed.append(
                    (url, ClaudeCacheError(path: url.path, reason: error.localizedDescription)))
            }
        }
        return result
    }
}
