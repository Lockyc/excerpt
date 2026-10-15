import Foundation

/// A file the filer left at the top of the library, and why.
public struct LibraryFilingFailure: Error, CustomStringConvertible, Sendable {
    public let url: URL
    public let reason: String

    public var description: String { "\(url.lastPathComponent) (\(reason))" }
}

/// Files the library's top level into `YYYY/MM-Month/` folders once a file is `flatAge` old by
/// creation date, so the folder opens on the last month's captures with everything older a
/// level down. Every visible file is filed, not only Excerpt's; folders and hidden files stay.
/// A master moves with its primary, filed by the primary's date, so re-editing still finds it;
/// a master whose primary is gone is filed by its own. Names never change: a name already taken
/// in the month folder leaves the file, or the whole pair, where it is and reports it.
public struct LibraryFiler: Sendable {
    public static let flatAge: TimeInterval = 30 * 24 * 60 * 60

    public struct Filed: Sendable {
        public var moved: [(from: URL, to: URL)] = []
        public var failed: [LibraryFilingFailure] = []
    }

    public let folder: URL
    public var timeZone: TimeZone

    public init(folder: URL, timeZone: TimeZone = .current) {
        self.folder = folder
        self.timeZone = timeZone
    }

    /// `2026/09-September`: the month folder, relative to the library, for a file created then.
    public func monthFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy'/'MM'-'MMMM"
        return formatter.string(from: date)
    }

    /// Moves every top-level file older than `flatAge` at `now` into its month folder. A missing
    /// library has nothing to file; one that can't be listed throws.
    @discardableResult
    public func file(now: Date) throws -> Filed {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile {
            return Filed()
        }
        var created: [String: Date] = [:]
        for url in contents {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            created[url.lastPathComponent] = values.creationDate ?? now
        }

        var filed = Filed()
        for name in created.keys.sorted() {
            // A master travels with its primary.
            if let primary = LibraryNaming.primaryName(forOriginal: name), created[primary] != nil {
                continue
            }
            guard let date = created[name], now.timeIntervalSince(date) > Self.flatAge else {
                continue
            }
            let master = LibraryNaming.originalName(forPrimary: name)
            let names = name.hasSuffix(".png") && created[master] != nil ? [name, master] : [name]
            move(names, into: folder.appendingPathComponent(monthFolder(for: date)), &filed)
        }
        return filed
    }

    /// Moves `names` (a file, or a primary and its master) together, or reports the first.
    private func move(_ names: [String], into month: URL, _ filed: inout Filed) {
        let first = folder.appendingPathComponent(names[0])
        if let taken = names.first(where: {
            FileManager.default.fileExists(atPath: month.appendingPathComponent($0).path)
        }) {
            let reason = "\(month.lastPathComponent) already has a \(taken)"
            filed.failed.append(LibraryFilingFailure(url: first, reason: reason))
            return
        }
        do {
            try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        } catch {
            filed.failed.append(
                LibraryFilingFailure(url: first, reason: error.localizedDescription))
            return
        }
        for name in names {
            let from = folder.appendingPathComponent(name)
            let to = month.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                filed.moved.append((from, to))
            } catch {
                filed.failed.append(
                    LibraryFilingFailure(url: from, reason: error.localizedDescription))
                return
            }
        }
    }
}
