import CoreGraphics

/// Where the HUD and the live preview sit on and around the scrolling region, in AppKit points:
/// the HUD centred on it when it is tall enough, the preview beside it while its screen has room.
/// Frames never show either window (the stream leaves out Excerpt's windows), so overlapping the
/// region costs only the user's view of what they cover. Both are pure functions of the region's
/// AppKit frame and the screen's visible frame, so any window that must sit where the HUD will
/// (the overlay's Start button) derives its frame from `hud`.
public enum ScrollChromeLayout {
    public static let gap: CGFloat = 12
    public static let previewWidth: CGFloat = 180
    public static let hudSize = CGSize(width: 520, height: 128)

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

    /// The clear height the HUD must leave above and below it to sit inside the region: room
    /// for the pointer, where scroll events land, beside the HUD that would take them.
    public static let scrollBand: CGFloat = 60

    /// Centred on the region while the region is `scrollBand` taller than the HUD on each
    /// side; else centred below it, else above it, else inside its bottom edge.
    public static func hud(size: CGSize, region: CGRect, visible: CGRect) -> CGRect {
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

    /// Where scroll events land: the middle of the region's taller part above or below the
    /// HUD, or the region's centre while the HUD sits outside it.
    public static func scrollPoint(region: CGRect, hud: CGRect) -> CGPoint {
        let covered = region.intersection(hud)
        guard !covered.isNull, !covered.isEmpty else {
            return CGPoint(x: region.midX, y: region.midY)
        }
        let above = region.maxY - covered.maxY
        let below = covered.minY - region.minY
        let y =
            above >= below ? (covered.maxY + region.maxY) / 2 : (region.minY + covered.minY) / 2
        return CGPoint(x: region.midX, y: y)
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
