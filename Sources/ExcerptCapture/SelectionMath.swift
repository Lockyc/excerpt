import CoreGraphics

public enum SelectionMath {
    /// Smallest side, in points, that counts as a deliberate selection. Anything smaller is a
    /// click or a slip and cancels the capture.
    public static let minimumSide: CGFloat = 4

    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The drag clamped to the display it started on: what is actually captured, so the size
    /// check judges the same rectangle the crop uses.
    public static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        rect(from: a, to: b).intersection(bounds)
    }

    public static func isCapturable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }
}
