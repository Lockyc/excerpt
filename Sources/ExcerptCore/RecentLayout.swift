import CoreGraphics

/// The Recent Captures panel's geometry, in the panel's bottom-left coordinates: a hero tile
/// across the top, two rows of three small tiles beneath it, and the footer along the bottom.
/// The hero is as tall as two small rows plus the gap between them, so every row edge lines up.
public enum RecentLayout {
    /// Small tiles per row: the grid's shape, which the selection's arrow keys follow too.
    public static let columns = 3
    public static let tileCount = 1 + 2 * columns
    /// The panel is `side` × `side` points.
    public static let side: CGFloat = 440
    public static let padding: CGFloat = 10
    public static let gap: CGFloat = 6
    public static let footerHeight: CGFloat = 32

    /// Tile frames, newest first: index 0 the hero, 1–3 the upper small row, 4–6 the lower.
    public static func tiles(side: CGFloat = side) -> [CGRect] {
        let gridBottom = padding + footerHeight + gap
        let gridHeight = side - padding - gridBottom
        let rowHeight = (gridHeight - 3 * gap) / 4
        let width = side - 2 * padding
        let smallWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)

        let lowerY = gridBottom
        let upperY = lowerY + rowHeight + gap
        let heroY = upperY + rowHeight + gap

        var frames = [CGRect(x: padding, y: heroY, width: width, height: 2 * rowHeight + gap)]
        for y in [upperY, lowerY] {
            for column in 0..<columns {
                frames.append(
                    CGRect(
                        x: padding + CGFloat(column) * (smallWidth + gap), y: y,
                        width: smallWidth, height: rowHeight))
            }
        }
        return frames
    }

    /// How many times taller than the tile's shape an image must be to fill the tile's width
    /// rather than fit inside it: fitted, a stitched page would be a sliver.
    public static let tallRatio: CGFloat = 2.5

    /// Where an image of `pixels` draws in a tile of `tile` points on a display of `scale`:
    /// fitted and centred, or, when it is more than `tallRatio` times the tile's shape tall,
    /// across the tile's width from the top, the rest falling below the tile to be cropped.
    /// Never more than one display pixel per image pixel, so a tiny capture stays sharp.
    public static func thumbnailFrame(pixels: CGSize, tile: CGSize, scale: CGFloat) -> CGRect {
        let isTall = pixels.height / pixels.width > tallRatio * tile.height / tile.width
        let fill =
            isTall
            ? tile.width / pixels.width
            : min(tile.width / pixels.width, tile.height / pixels.height)
        let factor = min(fill, 1 / scale)
        let size = CGSize(width: pixels.width * factor, height: pixels.height * factor)
        return CGRect(
            x: (tile.width - size.width) / 2,
            y: isTall ? tile.height - size.height : (tile.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    /// The rows of an image of `pixels`, counted from its top, that show in a tile of `tile`
    /// points on a display of `scale`, and where those rows draw in the tile: every row of an
    /// image that fits, and of a tall one only those `thumbnailFrame` leaves inside the tile, so a
    /// stitched page's thumbnail is decoded and held at the tile's pixels rather than the page's.
    public static func thumbnailRows(pixels: CGSize, tile: CGSize, scale: CGFloat) -> (
        rows: Int, frame: CGRect
    ) {
        let whole = thumbnailFrame(pixels: pixels, tile: tile, scale: scale)
        let factor = whole.width / pixels.width
        let shown = whole.maxY - max(whole.minY, 0)
        // The epsilon keeps a float's last bit from adding a whole row.
        let rows = min(Int(pixels.height), Int((shown / factor - 1e-6).rounded(.up)))
        let height = CGFloat(rows) * factor
        return (
            rows,
            CGRect(x: whole.minX, y: whole.maxY - height, width: whole.width, height: height)
        )
    }

    /// The footer's frame, along the bottom inside the padding.
    public static func footer(side: CGFloat = side) -> CGRect {
        CGRect(x: padding, y: padding, width: side - 2 * padding, height: footerHeight)
    }
}
