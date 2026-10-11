import CoreGraphics

/// The solid frame a document can draw around its render, so a capture pasted into an email or
/// a page stands apart from it. Drawn inside the edge, over the outermost pixels, so the render
/// keeps its size and every placement through its map.
public struct Border: Codable, Equatable, Sendable {
    public enum Width: String, Codable, CaseIterable, Sendable {
        case thin
        case medium
        case thick

        public var points: Double {
            switch self {
            case .thin: 2
            case .medium: 4
            case .thick: 8
            }
        }
    }

    public var color: Palette
    public var width: Width

    /// What turning the border on gives first.
    public static let initial = Border(color: .black, width: .medium)

    public init(color: Palette, width: Width) {
        self.color = color
        self.width = width
    }

    /// Fills the frame along the inside of a `width`×`height` canvas, at least one pixel thick.
    public func draw(
        in context: CGContext, width canvasWidth: Int, height canvasHeight: Int, scale: Double
    ) {
        let w = CGFloat(
            min(max(1, (width.points * scale).rounded()), Double(min(canvasWidth, canvasHeight))))
        let fullWidth = CGFloat(canvasWidth)
        let fullHeight = CGFloat(canvasHeight)
        context.saveGState()
        context.setFillColor(color.rgba.cgColor)
        context.fill([
            CGRect(x: 0, y: 0, width: fullWidth, height: w),
            CGRect(x: 0, y: fullHeight - w, width: fullWidth, height: w),
            CGRect(x: 0, y: 0, width: w, height: fullHeight),
            CGRect(x: fullWidth - w, y: 0, width: w, height: fullHeight),
        ])
        context.restoreGState()
    }
}
