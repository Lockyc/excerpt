import CoreGraphics

/// The editor's six colours.
public enum Palette: String, Codable, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case black

    /// What a new annotation gets.
    public static let initial = Palette.red

    public var rgba: RGBA {
        switch self {
        case .red: RGBA(r: 255, g: 59, b: 48, a: 255)
        case .orange: RGBA(r: 255, g: 149, b: 0, a: 255)
        case .yellow: RGBA(r: 255, g: 214, b: 10, a: 255)
        case .green: RGBA(r: 52, g: 199, b: 89, a: 255)
        case .blue: RGBA(r: 0, g: 122, b: 255, a: 255)
        case .black: RGBA(r: 0, g: 0, b: 0, a: 255)
        }
    }
}

/// The editor's three sizes. One control sets both the stroke of shapes and the size of text.
public enum StrokeWidth: String, Codable, CaseIterable, Sendable {
    case thin
    case medium
    case thick

    /// What a new annotation gets.
    public static let initial = StrokeWidth.medium

    /// Stroke width in points.
    public var points: Double {
        switch self {
        case .thin: 5
        case .medium: 10
        case .thick: 15
        }
    }

    /// Text size in points.
    public var textPoints: Double {
        switch self {
        case .thin: 20
        case .medium: 30
        case .thick: 45
        }
    }
}

/// What an annotation draws, in original pixels with the origin at the top left.
public enum Shape: Codable, Equatable, Sendable {
    /// The head is where the arrow points.
    case arrow(tail: CGPoint, head: CGPoint)
    case rectangle(rect: CGRect)
    /// `origin` is the top-left of the first line.
    case text(origin: CGPoint, string: String)
    case highlight(rect: CGRect)
    /// Destructive: pixelated over noise in the render, before crop and cuts.
    case blur(rect: CGRect)

    /// The same shape moved by `dx`, `dy`.
    public func offset(dx: Double, dy: Double) -> Shape {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: Double(p.x) + dx, y: Double(p.y) + dy) }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        switch self {
        case .arrow(let tail, let head): return .arrow(tail: move(tail), head: move(head))
        case .rectangle(let rect): return .rectangle(rect: move(rect))
        case .text(let origin, let string): return .text(origin: move(origin), string: string)
        case .highlight(let rect): return .highlight(rect: move(rect))
        case .blur(let rect): return .blur(rect: move(rect))
        }
    }

    public var isBlur: Bool {
        if case .blur = self { return true }
        return false
    }
}

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    /// Unique within its document (`EditDocument.nextAnnotationID`).
    public var id: Int
    public var shape: Shape
    public var color: Palette
    public var width: StrokeWidth

    public init(id: Int, shape: Shape, color: Palette = .initial, width: StrokeWidth = .initial) {
        self.id = id
        self.shape = shape
        self.color = color
        self.width = width
    }
}
