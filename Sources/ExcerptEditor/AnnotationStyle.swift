import ExcerptCore

/// What a new annotation gets: the colour, size and text background last chosen. The app keeps
/// it across launches.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: Palette
    public var width: StrokeWidth
    /// Whether new text sits on a pill of its colour.
    public var background: Bool

    public init(
        color: Palette = .initial, width: StrokeWidth = .initial, background: Bool = true
    ) {
        self.color = color
        self.width = width
        self.background = background
    }

    public static let initial = AnnotationStyle()
}
