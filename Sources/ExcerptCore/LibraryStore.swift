import CoreGraphics
import Foundation

public enum LibraryError: Error, Equatable, LocalizedError {
    /// A file named like this capture's master exists but isn't Excerpt's (no edits chunk).
    case foreignOriginal(URL)

    public var errorDescription: String? {
        switch self {
        case .foreignOriginal(let file):
            "A file named '\(file.lastPathComponent)' beside it isn't Excerpt's. Rename or move it, then save again."
        }
    }
}

/// A master that can't be read or parsed: `file` is the master, so an error shown for opening
/// the primary names the file that is bad.
public struct MasterUnreadable: Error {
    public let file: URL
    public let underlying: any Error
}

public struct LoadedCapture {
    public let primary: URL
    public let original: CGImage
    public let edits: EditDocument
    /// The primary opened as its own pixels although a master sits beside it: it was changed
    /// since Excerpt saved it, so saving it must replace that master's original with it.
    public let supersedesMaster: Bool
}

/// Reads and writes captures in the library folder. The primary is always the clean render; the
/// master holds the original pixels and the edits.
public struct LibraryStore: Sendable {
    public let folder: URL
    public let naming: LibraryNaming

    public init(folder: URL, naming: LibraryNaming = LibraryNaming()) {
        self.folder = folder
        self.naming = naming
    }

    /// Writes a new, unedited capture and returns its URL. Captures in the same second get
    /// ` (2)`, ` (3)`… and never overwrite each other. Creates the folder; an unwritable
    /// folder throws.
    public func saveCapture(_ image: CGImage, scale: Double, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try PNGCodec.encode(image, scale: scale)
        let base = naming.baseName(for: date)
        var counter = 1
        while true {
            let name = counter == 1 ? "\(base).png" : "\(base) (\(counter)).png"
            let url = folder.appendingPathComponent(name)
            let master = folder.appendingPathComponent(LibraryNaming.originalName(forPrimary: name))
            if !FileManager.default.fileExists(atPath: url.path)
                && !FileManager.default.fileExists(atPath: master.path)
            {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            }
            counter += 1
        }
    }

    /// The newest `limit` PNGs in the folder by creation date, masters left out (opening a
    /// primary loads its master's edits). Ordered by creation, not modification, because every
    /// save re-renders the primary. A missing folder has none.
    public func recentCaptures(limit: Int) throws -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        let dated = try contents.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".png"),
                LibraryNaming.primaryName(forOriginal: name) == nil
            else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { return nil }
            return (url, values.creationDate ?? .distantPast)
        }
        return
            dated
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
            .prefix(limit).map(\.0)
    }

    /// Writes the master first, then re-renders the primary, so a failure part-way never leaves
    /// an edited primary without its original. An existing master keeps its pixels: only its
    /// edits chunk is rewritten; the first edit, and every save `replacingMaster` (a primary
    /// loaded with `supersedesMaster`), encodes `original`. A file at the master's path that
    /// isn't Excerpt's throws `foreignOriginal` before anything is written. Returns the
    /// primary's PNG as written. The primary is rendered and encoded while the master is
    /// prepared: a first save encodes both in full.
    @discardableResult
    public func saveEdits(
        primary: URL, original: CGImage, edits: EditDocument, replacingMaster: Bool = false
    ) throws -> Data {
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        let primaryData = Started {
            try PNGCodec.encode(Renderer.render(original, edits: edits).image, scale: edits.scale)
        }
        let masterData: Data
        if FileManager.default.fileExists(atPath: master.path) {
            let existing = try Data(contentsOf: master)
            guard try Self.carriesEdits(existing) else {
                throw LibraryError.foreignOriginal(master)
            }
            if replacingMaster {
                masterData = try MasterFile.encode(original: original, edits: edits)
            } else {
                let json = String(decoding: try edits.encoded(), as: UTF8.self)
                masterData = try PNGChunks.settingText(
                    json, keyword: PNGChunks.editsKeyword, in: existing)
            }
        } else {
            masterData = try MasterFile.encode(original: original, edits: edits)
        }
        try masterData.write(to: master, options: .atomic)
        let data = try primaryData.value()
        try data.write(to: primary, options: .atomic)
        return data
    }

    /// True when the PNG carries the edits chunk; a file that isn't a PNG doesn't.
    private static func carriesEdits(_ data: Data) throws -> Bool {
        do {
            return try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data) != nil
        } catch PNGError.notPNG {
            return false
        }
    }

    /// Called with each image `load` would take pixels from, before any is decoded or rendered:
    /// the file, its size, and the edits it would be rendered with. Throwing refuses the open.
    public typealias Admission = (
        _ file: URL, _ width: Int, _ height: Int, _ edits: EditDocument
    ) throws -> Void

    /// Opens a primary or a master. A file is a master only when it carries the edits chunk, so
    /// a user's own `… original.png` opens as itself. A master opens with its edits. A primary
    /// opens through its master only while `MasterFile.reproduces` it; one changed since
    /// Excerpt saved it opens as its own pixels with `supersedesMaster` set, and one with no
    /// master opens as its own pixels, unedited. A master that can't be read or parsed throws `MasterUnreadable`.
    public func load(_ url: URL, admitting admit: Admission) throws -> LoadedCapture {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let (primary, master): (URL, URL)
        if let primaryName = LibraryNaming.primaryName(forOriginal: name) {
            (primary, master) = (directory.appendingPathComponent(primaryName), url)
        } else {
            (primary, master) = (
                url, directory.appendingPathComponent(LibraryNaming.originalName(forPrimary: name))
            )
        }
        var fromMaster: (original: CGImage, edits: EditDocument)?
        if FileManager.default.fileExists(atPath: master.path) {
            do {
                let data = try Data(contentsOf: master)
                if try Self.carriesEdits(data) {
                    let (original, edits) = try MasterFile.decode(data)
                    fromMaster = (original.image, edits ?? EditDocument(scale: original.scale))
                }
            } catch {
                throw MasterUnreadable(file: master, underlying: error)
            }
        }
        if let fromMaster {
            try admit(
                master, fromMaster.original.width, fromMaster.original.height, fromMaster.edits)
            if url == master {
                return LoadedCapture(
                    primary: primary, original: fromMaster.original, edits: fromMaster.edits,
                    supersedesMaster: false)
            }
        }
        let flat = try PNGCodec.decode(Data(contentsOf: url))
        let flatEdits = EditDocument(scale: flat.scale)
        try admit(url, flat.image.width, flat.image.height, flatEdits)
        if let fromMaster,
            MasterFile.reproduces(
                PixelBuffer(flat.image), from: fromMaster.original, edits: fromMaster.edits)
        {
            return LoadedCapture(
                primary: primary, original: fromMaster.original, edits: fromMaster.edits,
                supersedesMaster: false)
        }
        return LoadedCapture(
            primary: url, original: flat.image, edits: flatEdits,
            supersedesMaster: fromMaster != nil)
    }
}
