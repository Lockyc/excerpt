import CoreGraphics

/// The Recent Captures panel's geometry, in the panel's bottom-left coordinates: a hero tile
/// across the top, two rows of three small tiles beneath it, and the footer along the bottom.
/// The hero is as tall as two small rows plus the gap between them, so every row edge lines up.
public enum RecentLayout {
    public static let tileCount = 7
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
        let smallWidth = (width - 2 * gap) / 3

        let lowerY = gridBottom
        let upperY = lowerY + rowHeight + gap
        let heroY = upperY + rowHeight + gap

        var frames = [CGRect(x: padding, y: heroY, width: width, height: 2 * rowHeight + gap)]
        for y in [upperY, lowerY] {
            for column in 0..<3 {
                frames.append(
                    CGRect(
                        x: padding + CGFloat(column) * (smallWidth + gap), y: y,
                        width: smallWidth, height: rowHeight))
            }
        }
        return frames
    }

    /// The footer's frame, along the bottom inside the padding.
    public static func footer(side: CGFloat = side) -> CGRect {
        CGRect(x: padding, y: padding, width: side - 2 * padding, height: footerHeight)
    }
}
