import CoreGraphics

/// The solid frame a document can draw around its render, so a capture pasted into an email or
/// a page stands apart from it. Drawn outside the picture: the render grows by its width on
/// every side, and the map places everything inside it.
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
    /// Whether the frame grows the render. A border saved before it could is drawn inside the
    /// edge instead, over the outermost pixels, so its primary still reproduces.
    public var outside: Bool

    /// What turning the border on gives first.
    public static let initial = Border(color: .black, width: .medium)

    public init(color: Palette, width: Width, outside: Bool = true) {
        self.color = color
        self.width = width
        self.outside = outside
    }

    enum CodingKeys: String, CodingKey {
        case color
        case width
        case outside
    }

    /// A border without `outside` was saved when every border was drawn inside the edge.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(Palette.self, forKey: .color)
        width = try container.decode(Width.self, forKey: .width)
        outside = try container.decodeIfPresent(Bool.self, forKey: .outside) ?? false
    }

    /// The frame's thickness in rendered pixels, at least one.
    public func pixels(scale: Double) -> Int { Int(max(1, (width.points * scale).rounded())) }

    /// What the frame adds around the picture: its thickness on every side when outside.
    public func margin(scale: Double) -> Margin {
        guard outside else { return .zero }
        let w = pixels(scale: scale)
        return Margin(top: w, left: w, bottom: w, right: w)
    }

    /// Fills the frame along the inside of a `width`×`height` canvas — the picture grown by
    /// `margin(scale:)`, so an outside frame covers only what it added.
    public func draw(
        in context: CGContext, width canvasWidth: Int, height canvasHeight: Int, scale: Double
    ) {
        let w = CGFloat(min(pixels(scale: scale), canvasWidth, canvasHeight))
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
