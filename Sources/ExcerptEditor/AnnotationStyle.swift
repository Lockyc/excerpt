import ExcerptCore

/// What a new annotation gets: the colour, size and text background last chosen. The app keeps
/// it across launches.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: AnnotationColor
    /// The size of every new annotation but a marker.
    public var width: StrokeWidth
    /// The size of new markers — steps and clicks — chosen apart from `width` so resizing a box
    /// leaves the markers on it be.
    public var markerWidth: StrokeWidth
    /// Whether new text sits on a pill of its colour.
    public var background: Bool
    /// The colour the eyedropper last took from a capture, offered as the item bar's seventh
    /// swatch; nil until one is picked.
    public var lastSampled: RGBA?

    public init(
        color: AnnotationColor = .initial, width: StrokeWidth = .initial,
        markerWidth: StrokeWidth = .initial, background: Bool = true, lastSampled: RGBA? = nil
    ) {
        self.color = color
        self.width = width
        self.markerWidth = markerWidth
        self.background = background
        self.lastSampled = lastSampled
    }

    public static let initial = AnnotationStyle()

    /// A preference saved without `markerWidth` keeps the rest and gives markers the initial
    /// size.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try c.decode(AnnotationColor.self, forKey: .color),
            width: try c.decode(StrokeWidth.self, forKey: .width),
            markerWidth: try c.decodeIfPresent(StrokeWidth.self, forKey: .markerWidth) ?? .initial,
            background: try c.decode(Bool.self, forKey: .background),
            lastSampled: try c.decodeIfPresent(RGBA.self, forKey: .lastSampled))
    }
}
