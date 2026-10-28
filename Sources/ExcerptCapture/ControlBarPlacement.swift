import CoreGraphics

/// Where a recording's control bar sits, in AppKit points: inside the recorded area, where the
/// eye already is. The stream leaves out Excerpt's windows, so the bar is never in a frame, and
/// it is draggable for when it covers something being shown.
public enum ControlBarPlacement {
    public static let gap: CGFloat = 8

    /// Bottom centre of the part of the area on `screen` (the area's screen's visible frame),
    /// inset by `gap`. An area too small to hold it has the bar just below, else just above,
    /// else at the screen's bottom — always kept on `screen`.
    public static func frame(bar: CGSize, area: CGRect, screen: CGRect) -> CGRect {
        let visible = area.intersection(screen)
        if !visible.isNull, visible.width >= bar.width + 2 * gap,
            visible.height >= bar.height + 2 * gap
        {
            return CGRect(
                origin: CGPoint(x: visible.midX - bar.width / 2, y: visible.minY + gap), size: bar)
        }
        let x = min(max(area.midX - bar.width / 2, screen.minX), screen.maxX - bar.width)
        let y: CGFloat
        if area.minY - gap - bar.height >= screen.minY {
            y = area.minY - gap - bar.height
        } else if area.maxY + gap + bar.height <= screen.maxY {
            y = area.maxY + gap
        } else {
            y = screen.minY + gap
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: bar)
    }
}
