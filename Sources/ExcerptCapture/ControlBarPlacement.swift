import CoreGraphics

/// Where a recording's control bar sits, in AppKit points: outside the recorded area where the
/// screen has room, so the bar never covers what is being recorded.
public enum ControlBarPlacement {
    public static let gap: CGFloat = 8

    /// Below the area, centred; else above it; else right of it; else left of it. `screen` is
    /// the area's screen's visible frame. An area covering its whole screen has no outside:
    /// the bar goes to the bottom centre of the first of `otherScreens`, else inside the
    /// area's own bottom edge, inset by `gap`.
    public static func frame(
        bar: CGSize, area: CGRect, screen: CGRect, otherScreens: [CGRect]
    ) -> CGRect {
        func bottomCentre(of rect: CGRect) -> CGRect {
            CGRect(
                origin: CGPoint(x: rect.midX - bar.width / 2, y: rect.minY + gap), size: bar)
        }
        if area.contains(screen) {
            return bottomCentre(of: otherScreens.first ?? screen)
        }
        let x = min(max(area.midX - bar.width / 2, screen.minX), screen.maxX - bar.width)
        let y = min(max(area.midY - bar.height / 2, screen.minY), screen.maxY - bar.height)
        if area.minY - gap - bar.height >= screen.minY {
            return CGRect(origin: CGPoint(x: x, y: area.minY - gap - bar.height), size: bar)
        }
        if area.maxY + gap + bar.height <= screen.maxY {
            return CGRect(origin: CGPoint(x: x, y: area.maxY + gap), size: bar)
        }
        if area.maxX + gap + bar.width <= screen.maxX {
            return CGRect(origin: CGPoint(x: area.maxX + gap, y: y), size: bar)
        }
        if area.minX - gap - bar.width >= screen.minX {
            return CGRect(origin: CGPoint(x: area.minX - gap - bar.width, y: y), size: bar)
        }
        return bottomCentre(of: screen)
    }
}
