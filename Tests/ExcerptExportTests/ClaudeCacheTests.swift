import Foundation
import Testing

@testable import ExcerptExport

@Suite struct ClaudeCacheTests {
    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-cache-\(UUID().uuidString)")
    }

    @Test func folderNamesCarryNoSpacesOrSeparators() {
        #expect(
            ClaudeCache.folderName(for: "Excerpt 2026-10-10 at 09.43.29")
                == "Excerpt-2026-10-10-at-09.43.29")
        #expect(ClaudeCache.folderName(for: "a/b:c") == "a-b-c")
        #expect(ClaudeCache.folderName(for: "..") == "capture")
        #expect(ClaudeCache.folderName(for: ".") == "capture")
        #expect(ClaudeCache.folderName(for: "") == "capture")
        #expect(ClaudeCache.folderName(for: "../../etc") == "..-..-etc")
        #expect(ClaudeCache.folderName(for: "/") == "-")
        #expect(ClaudeCache.folderName(for: String(repeating: "x", count: 300)).count == 100)
    }

    @Test func folderNamesNeverEscapeTheRoot() {
        let root = URL(fileURLWithPath: "/cache/claude", isDirectory: true)
        let cache = ClaudeCache(root: root)
        for name in ["..", "../x", "/", "", "a/../..", "\0", String(repeating: "/", count: 500)] {
            let folder = cache.folder(for: name)
            #expect(folder.deletingLastPathComponent().path == root.path)
            #expect(!folder.lastPathComponent.contains("/"))
            #expect(folder.lastPathComponent != "..")
        }
    }

    @Test func entriesExpireAtSevenDays() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let entries: [(url: URL, modified: Date)] = [
            (URL(fileURLWithPath: "/c/fresh"), now.addingTimeInterval(-6.9 * day)),
            (URL(fileURLWithPath: "/c/week"), now.addingTimeInterval(-7 * day)),
            (URL(fileURLWithPath: "/c/old"), now.addingTimeInterval(-30 * day)),
            (URL(fileURLWithPath: "/c/future"), now.addingTimeInterval(day)),
        ]
        #expect(
            ClaudeCache.expired(entries, now: now).map(\.lastPathComponent) == ["week", "old"])
    }

    @Test func pruningRemovesOnlyExpiredFolders() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ClaudeCache(root: root)
        let none = try cache.prune(now: Date())  // no cache yet
        #expect(none.removed.isEmpty && none.failed.isEmpty)
        let old = root.appendingPathComponent("old")
        let fresh = root.appendingPathComponent("fresh")
        for folder in [old, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: old.path)
        let result = try cache.prune(now: now)
        #expect(result.removed.map(\.lastPathComponent) == ["old"])
        #expect(result.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func anEntryThatCannotBeRemovedIsNamedAndTheRestStillGo() throws {
        let root = scratchRoot()
        let manager = FileManager.default
        let stuckParent = root.appendingPathComponent("a-stuck")
        let stuck = stuckParent.appendingPathComponent("inner")
        let other = root.appendingPathComponent("b-old")
        try manager.createDirectory(at: stuck, withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        let now = Date()
        let aged = [FileAttributeKey.modificationDate: now.addingTimeInterval(-8 * 86_400)]
        // A read-only parent makes removing `inner`'s contents impossible: lock a-stuck itself.
        try manager.setAttributes(aged, ofItemAtPath: other.path)
        try manager.setAttributes(aged, ofItemAtPath: stuckParent.path)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuckParent.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuckParent.path)
            try? manager.removeItem(at: root)
        }
        // Locking the parent changed its mtime? setAttributes of permissions leaves mtime alone.
        let result = try ClaudeCache(root: root).prune(now: now)
        #expect(result.removed.map(\.lastPathComponent) == ["b-old"])
        #expect(result.failed.map(\.url.lastPathComponent) == ["a-stuck"])
        #expect(!manager.fileExists(atPath: other.path))
    }

    @Test func theRootIsCreatedUserOnly() throws {
        let root = scratchRoot().appendingPathComponent("nested/claude")
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent().deletingLastPathComponent())
        }
        let cache = ClaudeCache(root: root)
        try cache.ensureRoot()
        let mode =
            try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
            as? Int
        #expect(mode == 0o700)
        try cache.ensureRoot()  // idempotent
    }

    @Test func errorsCarryThePath() throws {
        let file = scratchRoot()
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = ClaudeCache(root: file.appendingPathComponent("claude"))
        do {
            try cache.ensureRoot()
            Issue.record("expected a failure")
        } catch let error as ClaudeCacheError {
            #expect(error.path.hasPrefix(file.path))
            #expect(error.description.contains(file.path))
        }
    }
}
