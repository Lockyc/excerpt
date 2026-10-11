import CoreGraphics

/// The solid frame a document can draw around its render, so a capture pasted into an email or
/// a page stands apart from it. Drawn inside the edge, over the outermost pixels, so the render
/// keeps its size and every placement through its map.
public enum Border {
    public static let points = 1.0
    public static let color = RGBA(r: 160, g: 160, b: 160, a: 255)

    /// Fills the frame along the inside of a `width`×`height` canvas, at least one pixel thick.
    public static func draw(in context: CGContext, width: Int, height: Int, scale: Double) {
        let w = CGFloat(min(max(1, (points * scale).rounded()), Double(min(width, height))))
        let canvasWidth = CGFloat(width)
        let canvasHeight = CGFloat(height)
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fill([
            CGRect(x: 0, y: 0, width: canvasWidth, height: w),
            CGRect(x: 0, y: canvasHeight - w, width: canvasWidth, height: w),
            CGRect(x: 0, y: 0, width: w, height: canvasHeight),
            CGRect(x: canvasWidth - w, y: 0, width: w, height: canvasHeight),
        ])
        context.restoreGState()
    }
}
