import Foundation

/// A capture too large to edit, carrying the file it is about.
public enum EditLimitsError: Error, Equatable, LocalizedError {
    case tooManyPixels(String, width: Int, height: Int)
    /// A master whose edits would render it past the pixel limits.
    case rendersTooLarge(String, width: Int, height: Int)

    /// The file the error is about.
    public var path: String {
        switch self {
        case .tooManyPixels(let path, _, _), .rendersTooLarge(let path, _, _): path
        }
    }

    /// Why the file can't be opened, as a sentence that doesn't name it.
    public var reason: String {
        let limits =
            "Excerpt opens images up to \(EditLimits.maximumPixels / 1_000_000) megapixels and \(EditLimits.maximumSide) pixels a side."
        return switch self {
        case .tooManyPixels(_, let width, let height): "It's \(width)×\(height) pixels; \(limits)"
        case .rendersTooLarge(_, let width, let height):
            "With its edits it renders at \(width)×\(height) pixels; \(limits)"
        }
    }

    public var errorDescription: String? { reason }
}

/// The largest image the editor opens, and the largest it renders.
public enum EditLimits {
    /// The largest capture Excerpt makes, with room: a scroll capture stops at the stitcher's
    /// height cap, and 6,720 pixels is a 6K display's full width at 2×. About 202 megapixels.
    public static let maximumPixels = Stitcher.defaultMaximumHeight * 6_720
    public static let maximumSide = 100_000

    /// Refuses a `width`×`height` original past the pixel limits, or one whose edits render it
    /// past them and larger than itself on either side, worked out from its size and the map
    /// before any pixel is decoded or drawn: the app checks every capture it opens in the editor
    /// this way. Only seams and the margin grow a render, so the second check refuses a crafted
    /// master's many cuts or far-flung annotations; a render no larger than an original within
    /// the limits is let through.
    public static func check(_ path: String, width: Int, height: Int, edits: EditDocument) throws {
        guard fits(width, height) else {
            throw EditLimitsError.tooManyPixels(path, width: width, height: height)
        }
        let map = Renderer.map(width: width, height: height, edits: edits)
        let (renderedWidth, renderedHeight) = (map.renderedWidth, map.renderedHeight)
        guard renderedWidth > width || renderedHeight > height else { return }
        guard fits(renderedWidth, renderedHeight) else {
            throw EditLimitsError.rendersTooLarge(
                path, width: renderedWidth, height: renderedHeight)
        }
    }

    private static func fits(_ width: Int, _ height: Int) -> Bool {
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return width > 0 && height > 0 && width <= maximumSide && height <= maximumSide
            && !overflow && product <= maximumPixels
    }
}
