import CoreGraphics

/// When a press on a preview becomes a drag rather than a click: a hand that wobbles a point or
/// two while clicking still copies.
public enum DragThreshold {
    /// How far the pointer must travel from the press, in points, before a drag starts.
    public static let distance: CGFloat = 3

    public static func isDrag(from press: CGPoint, to pointer: CGPoint) -> Bool {
        hypot(pointer.x - press.x, pointer.y - press.y) > distance
    }
}
