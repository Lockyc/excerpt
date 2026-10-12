import CoreGraphics

/// How a tall image is cut into tiles Claude reads at full resolution. Claude scales down an
/// image past its edge or visual-token limit, and once a conversation holds more than 20
/// images it rejects any image with a side over 2,000 px; Claude Code also scales any side past
/// 2,000 px down before sending. Tiles are in points: a Retina capture doubles its pixels
/// without adding legible text, so pixels past 1× only cost tokens.
public enum Tiling {
    /// The longest side a tile may have: the many-image limit, which is tighter than any
    /// current model's edge limit.
    public static let maximumEdge = 2_000
    /// The visual tokens Claude reads an image in without scaling it down.
    public static let maximumTokens = 4_784
    /// The side of one visual token's square patch, in pixels.
    public static let patch = 28
    /// The least any two neighbouring tiles share. A line of text no taller than this appears
    /// whole in at least one tile.
    public static let overlap = 100

    /// The tallest tile, in points, of an image `width` points wide that is within both
    /// `maximumEdge` and `maximumTokens`, in whole patches. An image wider than `maximumEdge`
    /// is scaled to it before Claude reads it, so its tiles are sized for that width.
    public static func tileLength(width: Int) -> Int {
        let columns = (min(max(width, 1), maximumEdge) + patch - 1) / patch
        return min(maximumEdge, maximumTokens / columns * patch)
    }

    /// Only the height is ever split; width is never tiled.
    ///
    /// The spans of `0..<length` the tiles cover. A length up to `fits` is one span. A longer
    /// one is cut into spans exactly `tile` long, each starting `tile - overlap` after the one
    /// before, with the last pulled back to end at `length`, so it shares more than `overlap`
    /// with its neighbour and never less. Empty for a length of zero or less.
    public static func spans(
        length: Int, tile: Int, overlap: Int = overlap, fits: Int? = nil
    ) -> [Range<Int>] {
        let fits = fits ?? tile
        precondition(tile > overlap && overlap >= 0 && fits >= tile, "tile geometry")
        guard length > 0 else { return [] }
        guard length > fits else { return [0..<length] }
        let stride = tile - overlap
        let count = (length - overlap + stride - 1) / stride
        return (0..<count).map { i in
            let start = i == count - 1 ? length - tile : i * stride
            return start..<(start + tile)
        }
    }

    /// The part of each span that owns what lies there: the spans' common rows split at their
    /// midpoint, so the bands partition the whole length. Anything no taller than the overlap
    /// whose middle lies in a span's band lies wholly inside that span.
    public static func ownedBands(_ spans: [Range<Int>]) -> [Range<Int>] {
        spans.indices.map { i in
            let lower =
                i == 0 ? spans[i].lowerBound : (spans[i].lowerBound + spans[i - 1].upperBound) / 2
            let upper =
                i == spans.count - 1
                ? spans[i].upperBound : (spans[i + 1].lowerBound + spans[i].upperBound) / 2
            return lower..<upper
        }
    }

    /// `image` at 1× (one pixel per point), cut into the tiles `spans` gives for its height.
    /// Only the height is split; the full width stays in every tile.
    public static func tiles(of image: CGImage, scale: Double) -> [CGImage] {
        let points = atPoints(image, scale: scale)
        return spans(length: points.height, tile: tileLength(width: points.width)).map { span in
            points.cropping(
                to: CGRect(x: 0, y: span.lowerBound, width: points.width, height: span.count))!
        }
    }

    /// `image` resampled to one pixel per point, always as 8-bit sRGB RGBA (Core's pixel layout)
    /// so a CMYK, 16-bit or indexed source cannot make a later PNG encode fail. Pixel size is
    /// unchanged at 1× or below.
    public static func atPoints(_ image: CGImage, scale: Double) -> CGImage {
        let factor = scale.isFinite ? max(scale, 1) : 1
        let width = max(1, Int((Double(image.width) / factor).rounded()))
        let height = max(1, Int((Double(image.height) / factor).rounded()))
        let context = PixelBuffer.makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
