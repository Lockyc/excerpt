import Foundation
import Testing

@testable import ExcerptCore

@Suite struct LibraryFilerTests {
    let utc = TimeZone(identifier: "UTC")!
    // 2026-10-15 12:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_792_065_600)
    let day: TimeInterval = 24 * 60 * 60

    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-filer-\(UUID().uuidString)")
            .appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func make(_ name: String, in folder: URL, created: Date) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        return url
    }

    func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    @Test func monthFolderIsYearThenNumberedMonth() {
        let filer = LibraryFiler(folder: URL(fileURLWithPath: "/x"), timeZone: utc)
        #expect(filer.monthFolder(for: now) == "2026/10-October")
        // 2026-01-31 23:59:59 UTC and a second later
        #expect(
            filer.monthFolder(for: Date(timeIntervalSince1970: 1_769_903_999)) == "2026/01-January")
        #expect(
            filer.monthFolder(for: Date(timeIntervalSince1970: 1_769_904_000)) == "2026/02-February"
        )
    }

    @Test func monthFolderFollowsTheTimeZone() {
        // 2026-01-31 20:00 UTC is already February in Brisbane (UTC+10).
        let date = Date(timeIntervalSince1970: 1_769_889_600)
        let brisbane = LibraryFiler(
            folder: URL(fileURLWithPath: "/x"),
            timeZone: TimeZone(identifier: "Australia/Brisbane")!)
        #expect(brisbane.monthFolder(for: date) == "2026/02-February")
    }

    @Test func filesOnlyWhatIsOlderThanTheFlatAge() throws {
        let folder = try tempFolder()
        try make("Old.png", in: folder, created: now - 31 * day)
        try make("Recent.png", in: folder, created: now - 29 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "2026/09-September/Old.png"))
        #expect(!exists(folder, "Old.png"))
        #expect(exists(folder, "Recent.png"))
        #expect(filed.moved.count == 1)
        #expect(filed.failed.isEmpty)
    }

    @Test func aMasterMovesWithItsPrimary() throws {
        let folder = try tempFolder()
        let created = now - 40 * day
        try make("Excerpt 2026-09-05 at 10.00.00.png", in: folder, created: created)
        // The master is written at the first edit, later than its primary.
        try make("Excerpt 2026-09-05 at 10.00.00 original.png", in: folder, created: now - 1 * day)
        try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "2026/09-September/Excerpt 2026-09-05 at 10.00.00.png"))
        #expect(exists(folder, "2026/09-September/Excerpt 2026-09-05 at 10.00.00 original.png"))
        #expect(!exists(folder, "Excerpt 2026-09-05 at 10.00.00 original.png"))
    }

    @Test func aMasterStaysWhileItsPrimaryIsRecent() throws {
        let folder = try tempFolder()
        try make("Excerpt 2026-10-10 at 10.00.00.png", in: folder, created: now - 5 * day)
        try make("Excerpt 2026-10-10 at 10.00.00 original.png", in: folder, created: now - 40 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(filed.moved.isEmpty)
        #expect(exists(folder, "Excerpt 2026-10-10 at 10.00.00 original.png"))
    }

    @Test func aMasterWithoutItsPrimaryIsFiledByItsOwnDate() throws {
        let folder = try tempFolder()
        try make("Excerpt 2026-08-01 at 10.00.00 original.png", in: folder, created: now - 70 * day)
        try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "2026/08-August/Excerpt 2026-08-01 at 10.00.00 original.png"))
    }

    @Test func aNameAlreadyTakenLeavesBothFilesAndIsReported() throws {
        let folder = try tempFolder()
        let month = folder.appendingPathComponent("2026/09-September")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data("filed".utf8).write(to: month.appendingPathComponent("Shot.png"))
        let shot = try make("Shot.png", in: folder, created: now - 40 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "Shot.png"))
        #expect(
            try Data(contentsOf: month.appendingPathComponent("Shot.png")) == Data("filed".utf8))
        #expect(filed.failed.map(\.url) == [shot])
        #expect(filed.moved.isEmpty)
    }

    @Test func aPairWhoseMasterNameIsTakenStaysTogether() throws {
        let folder = try tempFolder()
        let month = folder.appendingPathComponent("2026/09-September")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data("filed".utf8).write(to: month.appendingPathComponent("Shot original.png"))
        try make("Shot.png", in: folder, created: now - 40 * day)
        try make("Shot original.png", in: folder, created: now - 40 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "Shot.png"))
        #expect(exists(folder, "Shot original.png"))
        #expect(!exists(folder, "2026/09-September/Shot.png"))
        #expect(filed.failed.count == 1)
    }

    @Test func hiddenFilesAndFoldersStay() throws {
        let folder = try tempFolder()
        try make(".DS_Store", in: folder, created: now - 400 * day)
        let sub = folder.appendingPathComponent("timeline")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.creationDate: now - 400 * day], ofItemAtPath: sub.path)
        try make("Inside.png", in: sub, created: now - 400 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(filed.moved.isEmpty)
        #expect(exists(folder, ".DS_Store"))
        #expect(exists(folder, "timeline/Inside.png"))
    }

    @Test func anyFileIsFiledNotOnlyExcerpts() throws {
        let folder = try tempFolder()
        try make("CleanShot 2026-07-01 at 09.00.00.png", in: folder, created: now - 100 * day)
        try make("Recording.mp4", in: folder, created: now - 100 * day)
        try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "2026/07-July/CleanShot 2026-07-01 at 09.00.00.png"))
        #expect(exists(folder, "2026/07-July/Recording.mp4"))
    }

    @Test func aMissingFolderFilesNothing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-filer-\(UUID().uuidString)")
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)
        #expect(filed.moved.isEmpty && filed.failed.isEmpty)
    }
}

extension LibraryFilerTests {
    @Test func filerMovesARecordingWithItsMaster() throws {
        let folder = try tempFolder()
        for (ext, second) in [("gif", "00"), ("mp4", "01")] {
            let base = "Excerpt 2026-09-05 at 10.00.\(second)"
            try make("\(base).\(ext)", in: folder, created: now - 40 * day)
            try make("\(base) original.mov", in: folder, created: now - 1 * day)
        }
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(filed.failed.isEmpty)
        for name in [
            "Excerpt 2026-09-05 at 10.00.00.gif", "Excerpt 2026-09-05 at 10.00.00 original.mov",
            "Excerpt 2026-09-05 at 10.00.01.mp4", "Excerpt 2026-09-05 at 10.00.01 original.mov",
        ] {
            #expect(exists(folder, "2026/09-September/\(name)"))
            #expect(!exists(folder, name))
        }
    }

    @Test func aRecordingMasterStaysWhileItsPrimaryIsRecent() throws {
        let folder = try tempFolder()
        try make("Shot.gif", in: folder, created: now - 5 * day)
        try make("Shot original.mov", in: folder, created: now - 40 * day)
        let filed = try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(filed.moved.isEmpty)
    }

    @Test func aRecordingMasterWithoutItsPrimaryIsFiledByItsOwnDate() throws {
        let folder = try tempFolder()
        try make("Shot original.mov", in: folder, created: now - 70 * day)
        try LibraryFiler(folder: folder, timeZone: utc).file(now: now)

        #expect(exists(folder, "2026/08-August/Shot original.mov"))
    }
}
