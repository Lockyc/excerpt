import Foundation

/// A cache failure, carrying the path it happened at.
public struct ClaudeCacheError: Error, CustomStringConvertible, Sendable {
    public let path: String
    public let reason: String

    public var description: String { "\(path): \(reason)" }
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

    /// A capture's name as a folder name a Claude `@` reference can carry: anything but letters,
    /// digits, `.`, `_` and `-` becomes `-`, so `Excerpt 2026-10-10 at 09.43.29` is
    /// `Excerpt-2026-10-10-at-09.43.29`. A name of nothing but dots, or nothing, is `capture`.
    public static func folderName(for name: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }
            ).prefix(100))
        return mapped.allSatisfy { $0 == "." } ? "capture" : mapped
    }

    /// The folder for a capture: a direct child of the root, whatever the name.
    public func folder(for name: String) -> URL {
        root.appendingPathComponent(Self.folderName(for: name), isDirectory: true)
    }

    /// Makes the root, and any missing parents, readable by the user alone.
    public func ensureRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw ClaudeCacheError(path: root.path, reason: error.localizedDescription)
        }
    }

    /// The entries last modified `maximumAge` or more before `now`.
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
