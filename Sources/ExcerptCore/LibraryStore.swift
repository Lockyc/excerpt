import CoreGraphics
import Foundation

public struct LoadedCapture {
    public let primary: URL
    public let original: CGImage
    public let edits: EditDocument
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

    /// Writes the master first, then re-renders the primary, so a failure part-way never leaves
    /// an edited primary without its original. An existing master keeps its pixels: only its
    /// edits chunk is rewritten; the first edit encodes `original`.
    public func saveEdits(primary: URL, original: CGImage, edits: EditDocument) throws {
        let master = primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
        let masterData: Data
        if FileManager.default.fileExists(atPath: master.path) {
            let json = String(decoding: try edits.encoded(), as: UTF8.self)
            masterData = try PNGChunks.settingText(
                json, keyword: PNGChunks.editsKeyword, in: Data(contentsOf: master))
        } else {
            masterData = try MasterFile.encode(original: original, edits: edits)
        }
        try masterData.write(to: master, options: .atomic)
        let rendered = Renderer.render(original, edits: edits).image
        try PNGCodec.encode(rendered, scale: edits.scale).write(to: primary, options: .atomic)
    }

    /// Opens a primary or a master. A file is a master only when it carries the edits chunk, so
    /// a user's own `… original.png` opens as itself and its sibling is never overwritten. A
    /// primary without a master loads as an unedited capture.
    public func load(_ url: URL) throws -> LoadedCapture {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let candidates: [(primary: URL, master: URL)]
        if let primaryName = LibraryNaming.primaryName(forOriginal: name) {
            candidates = [(directory.appendingPathComponent(primaryName), url)]
        } else {
            candidates = [
                (
                    url,
                    directory.appendingPathComponent(LibraryNaming.originalName(forPrimary: name))
                )
            ]
        }
        for (primary, master) in candidates {
            guard let data = try? Data(contentsOf: master),
                (try? PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data)) != nil
            else { continue }
            let (original, edits) = try MasterFile.decode(data)
            return LoadedCapture(
                primary: primary, original: original.image,
                edits: edits ?? EditDocument(scale: original.scale))
        }
        let flat = try PNGCodec.decode(Data(contentsOf: url))
        return LoadedCapture(
            primary: url, original: flat.image, edits: EditDocument(scale: flat.scale))
    }
}
