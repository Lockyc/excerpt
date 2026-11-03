import ExcerptCore

/// What a new annotation gets: the colour, size and text background last chosen. The app keeps
/// it across launches.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: AnnotationColor
    public var width: StrokeWidth
    /// Whether new text sits on a pill of its colour.
    public var background: Bool
    /// The colour the eyedropper last took from a capture, offered as the item bar's seventh
    /// swatch; nil until one is picked.
    public var lastSampled: RGBA?

    public init(
        color: AnnotationColor = .initial, width: StrokeWidth = .initial, background: Bool = true,
        lastSampled: RGBA? = nil
    ) {
        self.color = color
        self.width = width
        self.background = background
        self.lastSampled = lastSampled
    }

    public static let initial = AnnotationStyle()
}
