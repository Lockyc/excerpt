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

extension SelectionMath {
    /// Where the start button sits for `selection`, in the overlay's top-left points: centred
    /// on the frame the HUD will take (centred on a tall enough selection, else below, above or
    /// inside its bottom edge), from `ScrollChromeLayout.hud` at the HUD's own size on the
    /// selection flipped into AppKit's bottom-left space.
    public static func startButtonFrame(for selection: CGRect, size: CGSize, in bounds: CGRect)
        -> CGRect
    {
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX, y: bounds.minY + bounds.maxY - rect.maxY, width: rect.width,
                height: rect.height)
        }
        let hud = flip(
            ScrollChromeLayout.hud(
                size: ScrollChromeLayout.hudSize, region: flip(selection), visible: bounds))
        return CGRect(
            x: hud.midX - size.width / 2, y: hud.midY - size.height / 2, width: size.width,
            height: size.height)
    }
}
