import CoreGraphics

/// AppKit's global space has its origin at the bottom-left of the primary screen; Quartz (and
/// ScreenCaptureKit / CGWindowList / CGEvent) at the top-left. The conversion is its own inverse.
public enum DisplayGeometry {
    public static func quartzRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKitRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        quartzRect(fromAppKit: rect, primaryHeight: primaryHeight)
    }

    /// A selection in display-local, top-left points → the pixel rect to crop from that
    /// display's still, rounded outward and clamped to the image.
    public static func pixelRect(forLocalPoints rect: CGRect, scale: CGFloat, imageSize: CGSize)
        -> CGRect
    {
        let scaled = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
            height: rect.height * scale
        ).integral
        return scaled.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// A pixel rect of a display's still → the display-local points it covers.
    public static func localPoints(forPixelRect rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale,
            height: rect.height / scale)
    }

    /// Display-local points → AppKit global points, for a display whose AppKit frame is
    /// `displayFrame`.
    public static func appKitRect(forLocalPoints rect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + rect.minX, y: displayFrame.maxY - rect.maxY, width: rect.width,
            height: rect.height)
    }

    /// A display-local point → Quartz global points, where CGEvents are posted.
    public static func quartzPoint(
        forLocalPoint point: CGPoint, displayFrame: CGRect, primaryHeight: CGFloat
    ) -> CGPoint {
        let origin = quartzRect(fromAppKit: displayFrame, primaryHeight: primaryHeight).origin
        return CGPoint(x: origin.x + point.x, y: origin.y + point.y)
    }
}
