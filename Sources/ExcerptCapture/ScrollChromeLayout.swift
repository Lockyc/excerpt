import CoreGraphics

/// Where the HUD and the live preview sit around the scrolling region, in AppKit points: beside
/// and below it while its screen has room, inside its edge when not. Frames never show either
/// window (the stream leaves out Excerpt's windows), so overlapping the region costs only the
/// user's view of that edge. Both are pure functions of the region's AppKit frame and the
/// screen's visible frame, so any window that must sit where the HUD will (the overlay's Start
/// button) derives its frame from `hud`.
public enum ScrollChromeLayout {
    public static let gap: CGFloat = 12
    public static let previewWidth: CGFloat = 180

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

    /// Centred below the region, else above it, else inside its bottom edge.
    public static func hud(size: CGSize, region: CGRect, visible: CGRect) -> CGRect {
        let x = clamp(region.midX - size.width / 2, visible.minX, visible.maxX - size.width)
        let y: CGFloat
        if region.minY - gap - size.height >= visible.minY {
            y = region.minY - gap - size.height
        } else if region.maxY + gap + size.height <= visible.maxY {
            y = region.maxY + gap
        } else {
            y = clamp(region.minY + gap, visible.minY, visible.maxY - size.height)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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
