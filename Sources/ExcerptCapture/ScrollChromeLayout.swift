import CoreGraphics

/// Where the pointer, the HUD, the live preview and the overlay's Start button sit on and around
/// the scrolling region, in AppKit points: the pointer where scroll events land, the HUD beside
/// it, the preview beside the region while its screen has room. Frames never show the HUD or the
/// preview (the stream leaves out Excerpt's windows), so overlapping the region costs only the
/// user's view of what they cover.
public enum ScrollChromeLayout {
    public static let gap: CGFloat = 12
    public static let previewWidth: CGFloat = 180
    public static let hudSize = CGSize(width: 380, height: 92)
    /// How far inside the region's edge scroll events land, so the window under the pointer is
    /// the region's and not a neighbour's.
    public static let pointerInset: CGFloat = 24

    /// Right of the region, else left of it, else inside its right edge; top-aligned with it.
    public static func preview(region: CGRect, visible: CGRect) -> CGRect {
        let width = previewWidth
        let height = min(region.height, visible.height)
        let x: CGFloat
        if region.maxX + gap + width <= visible.maxX {
            x = region.maxX + gap
        } else if region.minX - gap - width >= visible.minX {
            x = region.minX - gap - width
        } else {
            x = clamp(region.maxX - gap - width, visible.minX, visible.maxX - width)
        }
        let y = clamp(region.maxY - height, visible.minY, visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The clear height the Start button must leave above and below it to sit inside the region,
    /// so the selection still shows around it.
    public static let scrollBand: CGFloat = 60

    /// The Start button: centred on the region while the region is `scrollBand` taller than it
    /// on each side; else centred below it, else above it, else inside its bottom edge.
    public static func startButton(size: CGSize, region: CGRect, visible: CGRect) -> CGRect {
        let x = clamp(region.midX - size.width / 2, visible.minX, visible.maxX - size.width)
        let y: CGFloat
        if region.height - size.height >= 2 * scrollBand {
            y = clamp(region.midY - size.height / 2, visible.minY, visible.maxY - size.height)
        } else if region.minY - gap - size.height >= visible.minY {
            y = region.minY - gap - size.height
        } else if region.maxY + gap + size.height <= visible.maxY {
            y = region.maxY + gap
        } else {
            y = clamp(region.minY + gap, visible.minY, visible.maxY - size.height)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Where scroll events land: the pointer itself when it is at least `pointerInset` inside
    /// the region, else the nearest point that is (the centre, across a region too narrow or
    /// short for the inset), so the pointer moves as little as it can.
    public static func scrollPoint(pointer: CGPoint, region: CGRect) -> CGPoint {
        let dx = min(pointerInset, region.width / 2)
        let dy = min(pointerInset, region.height / 2)
        return CGPoint(
            x: clamp(pointer.x, region.minX + dx, region.maxX - dx),
            y: clamp(pointer.y, region.minY + dy, region.maxY - dy))
    }

    /// The HUD beside the pointer, `gap` from it: below and to the right, else on whichever
    /// side has room, kept on screen. It never covers the pointer while the screen has room
    /// around it, so the window under the pointer stays the page's.
    public static func hud(size: CGSize, beside pointer: CGPoint, visible: CGRect) -> CGRect {
        let x =
            pointer.x + gap + size.width <= visible.maxX
            ? pointer.x + gap : pointer.x - gap - size.width
        let y =
            pointer.y - gap - size.height >= visible.minY
            ? pointer.y - gap - size.height : pointer.y + gap
        return CGRect(
            x: clamp(x, visible.minX, visible.maxX - size.width),
            y: clamp(y, visible.minY, visible.maxY - size.height), width: size.width,
            height: size.height)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }

    /// How many rows of a stitch `stitchWidth` pixels wide fill a preview image area of `size`
    /// points at that width; at least one.
    public static func previewRows(stitchWidth: Int, size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(1, Int((Double(stitchWidth) * Double(size.height / size.width)).rounded(.down)))
    }
}
