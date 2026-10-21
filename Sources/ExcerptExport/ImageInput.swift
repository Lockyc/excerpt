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
    /// A master whose cuts would render it past the pixel limits.
    case rendersTooLarge(String, width: Int, height: Int)
    case damagedEdits(String, String)

    /// The file the error is about.
    public var path: String {
        switch self {
        case .missing(let path), .folder(let path), .unreadable(let path, _),
            .notAnImage(let path), .fileTooLarge(let path, _), .tooManyPixels(let path, _, _),
            .rendersTooLarge(let path, _, _), .damagedEdits(let path, _):
            path
        }
    }

    /// Why the file can't be read, as a sentence that doesn't name it, with `product` for the
    /// program: `excerpt` on the command line, `Excerpt` in the app.
    public func reason(product: String) -> String {
        let limits =
            "\(product) reads images up to \(ImageInput.maximumPixels / 1_000_000) megapixels and \(ImageInput.maximumSide) pixels a side."
        return switch self {
        case .missing: "No such file."
        case .folder: "It's a folder, not an image."
        case .unreadable(_, let reason):
            "It can't be read: \(reason)" + (reason.hasSuffix(".") ? "" : ".")
        case .notAnImage: "It isn't an image \(product) can read."
        case .fileTooLarge(_, let bytes):
            "It's \(bytes / 1_048_576) MB; \(product) reads images up to \(ImageInput.maximumBytes / 1_048_576) MB."
        case .tooManyPixels(_, let width, let height): "It's \(width)×\(height) pixels; \(limits)"
        case .rendersTooLarge(_, let width, let height):
            "With its edits it renders at \(width)×\(height) pixels; \(limits)"
        case .damagedEdits(_, let reason): reason
        }
    }

    /// The command line's wording: the path, then the reason.
    public var errorDescription: String? { "\(path): \(reason(product: "excerpt"))" }
}

/// An image file as `excerpt read` takes it: any format ImageIO decodes, upright. A master
/// comes with its edits. A primary comes with its master's edits only when re-rendering the
/// master reproduces it exactly; one changed since excerpt saved it (a redaction drawn over it
/// elsewhere) is read as itself, so nothing the master's original still holds can reach the
/// reader. Anything else is uncut, at the scale its DPI gives.
public struct ImageInput {
    public static let maximumBytes = 512 * 1_048_576
    /// The largest capture Excerpt makes, with room: a scroll capture stops at the stitcher's
    /// height cap, and 6,720 pixels is a 6K display's full width at 2×. About 202 megapixels.
    public static let maximumPixels = Stitcher.defaultMaximumHeight * 6_720
    public static let maximumSide = 100_000

    public let original: CGImage
    public let edits: EditDocument
    /// The capture's primary: the file itself, or for a master the primary beside it.
    public let primary: URL

    /// Checks the file before decoding any pixels: it is a regular file (symlinks followed), no
    /// larger than `maximumBytes`, an image, and its header gives no more than `maximumPixels`
    /// and no side over `maximumSide`. A master must also render within those limits. The
    /// limits are parameters so a test can reach them without a huge file.
    public static func load(
        _ url: URL, maximumPixels: Int = maximumPixels, maximumSide: Int = maximumSide
    ) throws -> ImageInput {
        let limits = Limits(pixels: maximumPixels, side: maximumSide)
        // The primary's bytes and decoded image end with this closure, before any master is
        // rendered against them.
        let step: Step = try {
            let path = url.path
            let file = try ImageFile(url, limits: limits)
            let fileName = url.lastPathComponent
            switch file.edits {
            case .unreadable:
                throw ImageInputError.damagedEdits(
                    path, EditDocumentError.damaged.localizedDescription)
            case .text(let json):
                let edits: EditDocument
                do {
                    edits = try EditDocument.decode(Data(json.utf8))
                } catch let error as EditDocumentError {
                    throw ImageInputError.damagedEdits(path, error.localizedDescription)
                }
                try limits.checkRender(path, width: file.width, height: file.height, edits: edits)
                let primaryName = LibraryNaming.primaryName(forOriginal: fileName) ?? fileName
                return .done(
                    ImageInput(
                        original: try file.image(path, upright: false), edits: edits,
                        primary: url.deletingLastPathComponent()
                            .appendingPathComponent(primaryName)))
            case .none: break
            }
            let scale = PNGCodec.scale(dpi: file.dpi)
            if file.isPNG, fileName.hasSuffix(".png"),
                LibraryNaming.primaryName(forOriginal: fileName) == nil,
                let master = MasterCandidate(
                    url.deletingLastPathComponent()
                        .appendingPathComponent(LibraryNaming.originalName(forPrimary: fileName)),
                    renderingTo: (file.width, file.height), limits: limits)
            {
                return .verify(
                    PixelBuffer(try file.image(path, upright: true)), master, scale: scale)
            }
            return .done(
                ImageInput(
                    original: try file.image(path, upright: true),
                    edits: EditDocument(scale: scale), primary: url))
        }()
        switch step {
        case .done(let input):
            return input
        case .verify(let primary, let master, let scale):
            if let original = master.original(ifItRenders: primary) {
                return ImageInput(original: original, edits: master.edits, primary: url)
            }
            return ImageInput(
                original: primary.makeImage(), edits: EditDocument(scale: scale), primary: url)
        }
    }

    /// Refuses a `width`×`height` original past the pixel limits, or one whose edits render it
    /// past them and larger than itself on either side, worked out from its size and the map
    /// before any pixel is decoded or drawn: the app checks every capture it opens in the editor
    /// this way. Only seams and the margin grow a render, so the second check refuses a crafted
    /// master's many cuts or far-flung annotations; a render no larger than an original within
    /// the limits is let through.
    public static func checkEditable(
        _ path: String, width: Int, height: Int, edits: EditDocument
    ) throws {
        let limits = Limits(pixels: maximumPixels, side: maximumSide)
        try limits.check(path, width: width, height: height)
        let map = Renderer.map(width: width, height: height, edits: edits)
        guard map.renderedWidth > width || map.renderedHeight > height else { return }
        try limits.checkRender(path, width: width, height: height, edits: edits)
    }

    private enum Step {
        case done(ImageInput)
        /// A primary, as 8-bit sRGB RGBA, with a master that may have rendered it.
        case verify(PixelBuffer, MasterCandidate, scale: Double)
    }
}

/// The master beside a primary, checked like any input, whose edits render at the primary's
/// size: the last check, comparing pixels, is `original(ifItRenders:)`.
private struct MasterCandidate {
    let file: ImageFile
    let path: String
    let edits: EditDocument

    init?(_ url: URL, renderingTo size: (width: Int, height: Int), limits: Limits) {
        guard let file = try? ImageFile(url, limits: limits), case .text(let json) = file.edits,
            let edits = try? EditDocument.decode(Data(json.utf8))
        else { return nil }
        let map = Renderer.map(width: file.width, height: file.height, edits: edits)
        guard map.renderedWidth == size.width, map.renderedHeight == size.height,
            (try? limits.check(url.path, width: size.width, height: size.height)) != nil
        else { return nil }
        self.file = file
        self.path = url.path
        self.edits = edits
    }

    /// The master's original when its render is `primary` pixel for pixel. The primary's file
    /// and decode are already released; what remains at the peak is the primary's pixels, the
    /// master's decoded original, the renderer's working images and the render's pixels:
    /// measured at 3.3 GB resident for `excerpt read` on a 104-megapixel primary with its
    /// master (3456 × 30,000 at 2×), about 32 bytes per rendered pixel, so near 6.4 GB at
    /// `maximumPixels`.
    func original(ifItRenders primary: PixelBuffer) -> CGImage? {
        guard let original = try? file.image(path, upright: false),
            MasterFile.reproduces(primary, from: original, edits: edits)
        else { return nil }
        return original
    }
}

private struct Limits {
    let pixels: Int
    let side: Int

    func check(_ path: String, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= side, height <= side, fits(width, height) else {
            throw ImageInputError.tooManyPixels(path, width: width, height: height)
        }
    }

    /// Every cut adds a seam gap and an annotation past the edge a margin, so a render can be far
    /// larger than its original: its size is checked from the map before anything is drawn.
    func checkRender(_ path: String, width: Int, height: Int, edits: EditDocument) throws {
        let map = Renderer.map(width: width, height: height, edits: edits)
        let (renderedWidth, renderedHeight) = (map.renderedWidth, map.renderedHeight)
        guard renderedWidth <= side, renderedHeight <= side, fits(renderedWidth, renderedHeight)
        else {
            throw ImageInputError.rendersTooLarge(
                path, width: renderedWidth, height: renderedHeight)
        }
    }

    private func fits(_ width: Int, _ height: Int) -> Bool {
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && product <= pixels
    }
}

/// A file read and its image header checked, with no pixels decoded yet.
private struct ImageFile {
    /// A PNG's excerpt edits chunk: absent, its text, or present but unreadable.
    enum Edits {
        case none
        case text(String)
        case unreadable
    }

    let source: CGImageSource
    let properties: [CFString: Any]
    let width: Int
    let height: Int
    let isPNG: Bool
    let edits: Edits

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
            guard let scan = try? PNGChunks.scan(data, keyword: PNGChunks.editsKeyword),
                scan.isComplete
            else { throw ImageInputError.notAnImage(path) }
            if !scan.carriesText {
                edits = .none
            } else if let json = scan.text {
                edits = .text(json)
            } else {
                edits = .unreadable
            }
        } else {
            guard type != UTType.jpeg.identifier || JPEGStructure.isComplete(data) else {
                throw ImageInputError.notAnImage(path)
            }
            edits = .none
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
