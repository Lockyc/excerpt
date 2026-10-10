import CoreGraphics
import Darwin
import ExcerptCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageInputError: Error, Equatable, LocalizedError {
    case missing(String)
    case folder(String)
    case unreadable(String, String)
    case notAnImage(String)
    case fileTooLarge(String, bytes: Int)
    case tooManyPixels(String, width: Int, height: Int)
    case damagedEdits(String, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): "\(path): no such file"
        case .folder(let path): "\(path) is a folder, not an image"
        case .unreadable(let path, let reason): "\(path) can't be read: \(reason)"
        case .notAnImage(let path): "\(path) isn't an image excerpt can read"
        case .fileTooLarge(let path, let bytes):
            "\(path) is \(bytes / 1_048_576) MB; excerpt reads images up to \(ImageInput.maximumBytes / 1_048_576) MB"
        case .tooManyPixels(let path, let width, let height):
            "\(path) is \(width)×\(height) pixels; excerpt reads images up to \(ImageInput.maximumPixels / 1_000_000) megapixels and \(ImageInput.maximumSide) pixels a side"
        case .damagedEdits(let path, let reason): "\(path): \(reason)"
        }
    }
}

/// An image file as `excerpt read` takes it: any format ImageIO decodes, upright. A master
/// comes with its edits. A primary comes with its master's edits only when re-rendering the
/// master reproduces it exactly; one changed since excerpt saved it (a redaction drawn over it
/// elsewhere) is read as itself, so nothing the master's original still holds can reach the
/// reader. Anything else is uncut, at the scale its DPI gives.
public struct ImageInput {
    public static let maximumBytes = 512 * 1_048_576
    public static let maximumPixels = 100_000_000
    public static let maximumSide = 100_000

    public let original: CGImage
    public let edits: EditDocument
    /// The capture's name: the primary's file name without its extension.
    public let name: String

    /// Checks the file before decoding any pixels: it is a regular file (symlinks followed), no
    /// larger than `maximumBytes`, an image, and its header gives no more than `maximumPixels`
    /// and no side over `maximumSide`. A master must also render within those limits. The
    /// limits are parameters so a test can reach them without a huge file.
    public static func load(
        _ url: URL, maximumPixels: Int = maximumPixels, maximumSide: Int = maximumSide
    ) throws -> ImageInput {
        let limits = Limits(pixels: maximumPixels, side: maximumSide)
        let path = url.path
        let file = try ImageFile(url, limits: limits)
        let fileName = url.lastPathComponent

        if let json = file.editsText {
            let edits: EditDocument
            do {
                edits = try EditDocument.decode(Data(json.utf8))
            } catch let error as EditDocumentError {
                throw ImageInputError.damagedEdits(path, error.localizedDescription)
            }
            try limits.checkRender(path, width: file.width, height: file.height, edits: edits)
            let primaryName = LibraryNaming.primaryName(forOriginal: fileName) ?? fileName
            return ImageInput(
                original: try file.image(path, upright: false), edits: edits,
                name: URL(fileURLWithPath: primaryName).deletingPathExtension().lastPathComponent)
        }

        let flat = try file.image(path, upright: true)
        if file.isPNG, fileName.hasSuffix(".png"),
            LibraryNaming.primaryName(forOriginal: fileName) == nil,
            let master = verifiedMaster(
                url.deletingLastPathComponent()
                    .appendingPathComponent(LibraryNaming.originalName(forPrimary: fileName)),
                rendering: flat, limits: limits)
        {
            return ImageInput(
                original: master.original, edits: master.edits,
                name: url.deletingPathExtension().lastPathComponent)
        }
        return ImageInput(
            original: flat, edits: EditDocument(scale: PNGCodec.scale(dpi: file.dpi)),
            name: url.deletingPathExtension().lastPathComponent)
    }

    /// The master at `url` when it passes every check the input did and its render is `primary`
    /// pixel for pixel, both as 8-bit sRGB RGBA; nil otherwise.
    private static func verifiedMaster(
        _ url: URL, rendering primary: CGImage, limits: Limits
    ) -> (original: CGImage, edits: EditDocument)? {
        guard let master = try? ImageFile(url, limits: limits), let json = master.editsText,
            let edits = try? EditDocument.decode(Data(json.utf8))
        else { return nil }
        let map = Renderer.map(width: master.width, height: master.height, edits: edits)
        guard map.renderedWidth == primary.width, map.renderedHeight == primary.height,
            (try? limits.checkRender(
                url.path, width: master.width, height: master.height, edits: edits)) != nil,
            let original = try? master.image(url.path, upright: false)
        else { return nil }
        let rendered = Renderer.render(original, edits: edits).image
        guard PixelBuffer(rendered) == PixelBuffer(primary) else { return nil }
        return (original, edits)
    }
}

private struct Limits {
    let pixels: Int
    let side: Int

    func check(_ path: String, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= side, height <= side,
            width.multipliedReportingOverflow(by: height).partialValue <= pixels
        else { throw ImageInputError.tooManyPixels(path, width: width, height: height) }
    }

    /// Every cut adds a seam gap, so a render can be far larger than its original: its size is
    /// checked from the map before anything is drawn.
    func checkRender(_ path: String, width: Int, height: Int, edits: EditDocument) throws {
        let map = Renderer.map(width: width, height: height, edits: edits)
        try check(path, width: map.renderedWidth, height: map.renderedHeight)
    }
}

/// A file read and its image header checked, with no pixels decoded yet.
private struct ImageFile {
    let source: CGImageSource
    let properties: [CFString: Any]
    let width: Int
    let height: Int
    let isPNG: Bool
    /// The excerpt edits chunk, when this is a PNG carrying one (a master).
    let editsText: String?

    var dpi: Double? { properties[kCGImagePropertyDPIWidth] as? Double }

    init(_ url: URL, limits: Limits) throws {
        let path = url.path
        let data = try Self.read(path)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageInputError.notAnImage(path) }
        try limits.check(path, width: width, height: height)
        isPNG = type == UTType.png.identifier
        if isPNG {
            // ImageIO decodes a PNG cut short without complaint, filling the rest with grey.
            guard let types = try? PNGChunks.chunkTypes(in: data), types.last == "IEND" else {
                throw ImageInputError.notAnImage(path)
            }
            editsText =
                types.contains("iTXt")
                ? (try? PNGChunks.text(keyword: PNGChunks.editsKeyword, in: data)) ?? nil : nil
        } else {
            editsText = nil
        }
        self.source = source
        self.properties = properties
        self.width = width
        self.height = height
    }

    /// The first frame, decoded now so a truncated file fails here. `upright` applies the EXIF
    /// orientation, as a phone photo needs; a master's pixels are the ones its edits address.
    func image(_ path: String, upright: Bool) throws -> CGImage {
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImageInputError.notAnImage(path)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if upright, orientation != 1 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let image, image.width > 0, image.height > 0 else {
            throw ImageInputError.notAnImage(path)
        }
        return image
    }

    /// The file's bytes. It is opened without blocking and checked through the open descriptor,
    /// so a FIFO or device is refused rather than read, a symlink is judged by its target, and
    /// nothing can be swapped in between the check and the read.
    static func read(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: throw ImageInputError.missing(path)
            case EACCES, EPERM: throw ImageInputError.unreadable(path, "permission denied")
            default: throw ImageInputError.unreadable(path, String(cString: strerror(code)))
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ImageInputError.unreadable(path, String(cString: strerror(errno)))
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw ImageInputError.folder(path)
        default: throw ImageInputError.unreadable(path, "not a regular file")
        }
        let bytes = Int(status.st_size)
        guard bytes <= ImageInput.maximumBytes else {
            throw ImageInputError.fileTooLarge(path, bytes: bytes)
        }
        let data: Data
        do {
            data = try handle.read(upToCount: bytes + 1) ?? Data()
        } catch {
            throw ImageInputError.unreadable(path, error.localizedDescription)
        }
        guard data.count <= ImageInput.maximumBytes else {
            throw ImageInputError.fileTooLarge(path, bytes: data.count)
        }
        return data
    }
}
