import Foundation
import Testing

@testable import ExcerptExport

@Suite struct ClaudeCacheTests {
    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-cache-\(UUID().uuidString)")
    }

    private func folderName(_ name: String, in folder: String = "/captures") -> String {
        ClaudeCache.folderName(for: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    @Test func folderNamesCarryNoSpacesOrSeparators() {
        let name = folderName("Excerpt 2026-10-10 at 09.43.29.png")
        #expect(name.hasPrefix("Excerpt-2026-10-10-at-09.43.29-"))
        #expect(!name.contains(" ") && !name.contains("/") && !name.contains(":"))
        #expect(folderName("ok-name_1.2.png").hasPrefix("ok-name_1.2-"))
        #expect(folderName("a b.png").hasPrefix("a-b-"))
        #expect(folderName(".png").hasPrefix("-"))
        #expect(folderName("..x.png").hasPrefix("-.x-"))
        #expect(!folderName(".hidden").hasPrefix("."))
        #expect(folderName(String(repeating: "x", count: 250) + ".png").count <= 100)
    }

    @Test func eachPrimaryGetsItsOwnFolder() {
        let prefix = String(repeating: "x", count: 120)
        let names = [
            "a b", "a-b", "日本語", "ñandú", "A", "a", "capture", "-",
            prefix + "1", prefix + "2", "-x",
        ]
        let folders = names.map { folderName($0 + ".png") }
        #expect(Set(folders).count == names.count)
        #expect(Set(folders.map { $0.lowercased() }).count == names.count)
        #expect(folderName("shot.png", in: "/a") != folderName("shot.png", in: "/b"))
        #expect(folderName("shot.png", in: "/a") == folderName("shot.png", in: "/a/x/.."))
        #expect(folders.allSatisfy { !$0.hasPrefix(".") && $0.count <= 100 })
    }

    @Test func folderNamesNeverEscapeTheRoot() {
        let root = URL(fileURLWithPath: "/cache/claude", isDirectory: true)
        let cache = ClaudeCache(root: root)
        for path in [
            "/..", "/a/..", "/", "/a/b/../..", "/\0", "/" + String(repeating: ".", count: 500),
        ] {
            let folder = cache.folder(for: URL(fileURLWithPath: path))
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
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuckParent.path)
            try? manager.removeItem(at: root)
        }
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        let now = Date()
        let aged = [FileAttributeKey.modificationDate: now.addingTimeInterval(-8 * 86_400)]
        // A read-only parent makes removing `inner`'s contents impossible: lock a-stuck itself.
        try manager.setAttributes(aged, ofItemAtPath: other.path)
        try manager.setAttributes(aged, ofItemAtPath: stuckParent.path)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuckParent.path)
        // Locking the parent changed its mtime? setAttributes of permissions leaves mtime alone.
        let result = try ClaudeCache(root: root).prune(now: now)
        #expect(result.removed.map(\.lastPathComponent) == ["b-old"])
        #expect(result.failed.map(\.url.lastPathComponent) == ["a-stuck"])
        #expect(!manager.fileExists(atPath: other.path))
    }

    @Test func aFreshStagingFolderSurvivesPruning() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging-abc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let result = try ClaudeCache(root: root).prune(now: Date())
        #expect(result.removed.isEmpty && result.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.path))
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
