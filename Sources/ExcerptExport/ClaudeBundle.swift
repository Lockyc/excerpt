import CoreGraphics
import ExcerptCore
import Foundation

public enum ClaudeBundleError: Error, LocalizedError {
    /// The cache folder couldn't be made or written: unwritable, or the disk is full.
    case cacheUnwritable(URL, any Error)
    /// The cache folder couldn't be listed, so its expired bundles couldn't be pruned.
    case cacheUnreadable(URL, any Error)
    /// The recogniser failed on the render.
    case recognitionFailed(any Error)
    /// A tile couldn't be encoded as a PNG; the cache is not at fault.
    case tileEncodingFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .cacheUnwritable(let folder, let error):
            "Couldn't write to \(folder.path): \(error.localizedDescription)"
        case .cacheUnreadable(let folder, let error):
            "Couldn't read \(folder.path): \(error.localizedDescription)"
        case .recognitionFailed(let error):
            "Couldn't read the text: \(error.localizedDescription)"
        case .tileEncodingFailed(let error):
            "Couldn't encode an image tile: \(error.localizedDescription)"
        }
    }
}

/// A capture shaped for Claude: tiles at 1× and the text, in the capture's cache folder.
public struct ClaudeBundle: Sendable {
    public let folder: URL
    /// Top to bottom.
    public let tiles: [URL]
    /// `text.md`.
    public let textFile: URL
    /// What `text.md` holds.
    public let text: String
    /// Expired cache entries the prune before this export could not remove.
    public let pruneFailures: [(url: URL, error: ClaudeCacheError)]

    /// `@` references to every tile, then `text.md`, on one line: what the clipboard gets. One
    /// line, because a terminal may fold a pasted block of many lines into a placeholder.
    public var references: String {
        (tiles + [textFile]).map { "@" + $0.path }.joined(separator: " ")
    }

    /// Renders `original` with `edits`, reads its text and tiles it, then replaces the cache
    /// folder of the capture whose primary is at `primary` with the result. Tiles and text come from the render alone, which is the
    /// primary's pixels: a cut band is in neither, and a blurred area is only `BlurRenderer`'s
    /// blocks, which hold no readable text. Expired folders
    /// are pruned first; entries that could not be removed are reported in `pruneFailures`.
    /// The bundle is built in a hidden staging folder (a dot-name, which `folderName` never
    /// yields) and swapped in atomically, so a failure leaves the previous bundle in place.
    public static func write(
        original: CGImage, edits: EditDocument, primary: URL, cache: ClaudeCache,
        recognizer: any TextRecognizer, now: Date = Date()
    ) throws -> ClaudeBundle {
        let pruned: ClaudeCache.Pruned
        do {
            pruned = try cache.prune(now: now)
        } catch {
            throw ClaudeBundleError.cacheUnreadable(cache.root, error)
        }
        let render = Renderer.render(original, edits: edits)
        let text: String
        do {
            text = try CaptureText.read(
                render.image, map: render.map, scale: edits.scale, recognizer: recognizer)
        } catch let error as CaptureTextError {
            throw error
        } catch {
            throw ClaudeBundleError.recognitionFailed(error)
        }
        let tiles = Tiling.tiles(of: render.image, scale: edits.scale)
        let encoded: [Data]
        do {
            encoded = try tiles.map { try PNGCodec.encode($0, scale: 1) }
        } catch {
            throw ClaudeBundleError.tileEncodingFailed(error)
        }

        let manager = FileManager.default
        let folder = cache.folder(for: primary)
        let staging = cache.root.appendingPathComponent(
            ".\(folder.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        let digits = String(tiles.count).count
        let names = tiles.indices.map {
            "tile-\(padded($0 + 1, digits))-of-\(padded(tiles.count, digits)).png"
        }
        let swapped: URL
        do {
            try cache.ensureRoot()
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for (data, tileName) in zip(encoded, names) {
                try data.write(to: staging.appendingPathComponent(tileName))
            }
            try Data(text.utf8).write(to: staging.appendingPathComponent("text.md"))
            swapped = try manager.replaceItemAt(folder, withItemAt: staging) ?? folder
        } catch {
            try? manager.removeItem(at: staging)
            throw ClaudeBundleError.cacheUnwritable(cache.root, error)
        }
        return ClaudeBundle(
            folder: swapped, tiles: names.map { swapped.appendingPathComponent($0) },
            textFile: swapped.appendingPathComponent("text.md"), text: text,
            pruneFailures: pruned.failed)
    }

    /// The bundle for the image file at `url`, taken as `ImageInput.load` takes it: a primary
    /// brings its master's edits only while it is exactly the master's render, so one changed
    /// since it was saved exports as its own pixels. The one way a file reaches Claude, for
    /// `excerpt read` and a thumbnail's For Claude alike.
    public static func write(
        contentsOf url: URL, cache: ClaudeCache, recognizer: any TextRecognizer,
        now: Date = Date()
    ) throws -> ClaudeBundle {
        let input = try ImageInput.load(url)
        return try write(
            original: input.original, edits: input.edits, primary: input.primary, cache: cache,
            recognizer: recognizer, now: now)
    }

    private static func padded(_ number: Int, _ digits: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
