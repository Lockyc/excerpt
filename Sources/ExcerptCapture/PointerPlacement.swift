import CoreGraphics

/// Where a thumbnail shown at the pointer sits, and how far the pointer may stray before it
/// docks in the corner. AppKit's bottom-left screen points throughout.
public enum PointerPlacement {
    /// How far past the thumbnail's edge the pointer may go and still be near it.
    public static let safetyMargin: CGFloat = 60

    /// A frame of `size` centred on `pointer`, slid inside `visible`; one larger than `visible`
    /// pins to its bottom-left.
    public static func frame(size: CGSize, centredOn pointer: CGPoint, within visible: CGRect)
        -> CGRect
    {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            max(low, min(value, high))
        }
        let x = clamp(pointer.x - size.width / 2, visible.minX, visible.maxX - size.width)
        let y = clamp(pointer.y - size.height / 2, visible.minY, visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public static func isInSafetyZone(_ pointer: CGPoint, around frame: CGRect) -> Bool {
        frame.insetBy(dx: -safetyMargin, dy: -safetyMargin).contains(pointer)
    }
}
