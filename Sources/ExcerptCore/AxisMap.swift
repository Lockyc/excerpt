/// How one axis of the original maps onto the rendered image once its bands are removed and
/// each is replaced by a fixed-size gap. This is the single coordinate map: renderer, editor
/// and annotations all place things through it.
public struct AxisMap: Equatable, Sendable {
    /// A kept span of original lines and where it starts in the rendered image.
    public struct Segment: Equatable, Sendable {
        public let source: Range<Int>
        public let destination: Int
    }

    /// A seam: where it sits in the rendered image and how many original lines it replaces.
    public struct Gap: Equatable, Sendable {
        public let destination: Range<Int>
        public let removed: Int
    }

    public let segments: [Segment]
    public let gaps: [Gap]
    public let renderedLength: Int

    /// `bands` must be normalised (`CutSet.normalized`).
    public init(extent: Int, bands: [Range<Int>], gap: Int) {
        var segments: [Segment] = []
        var gaps: [Gap] = []
        var source = 0
        var destination = 0
        for band in bands {
            if band.lowerBound > source {
                segments.append(Segment(source: source..<band.lowerBound, destination: destination))
                destination += band.lowerBound - source
            }
            gaps.append(Gap(destination: destination..<(destination + gap), removed: band.count))
            destination += gap
            source = band.upperBound
        }
        if source < extent {
            segments.append(Segment(source: source..<extent, destination: destination))
            destination += extent - source
        }
        self.segments = segments
        self.gaps = gaps
        self.renderedLength = destination
    }

    /// The rendered position of original position `v`, or nil when `v` lies strictly inside a
    /// removed band, or lies at an outer image edge (0 or the extent) that a band touches. A
    /// band's boundary maps to the edge of the kept segment beside it.
    public func map(_ v: Double) -> Double? {
        for segment in segments
        where v >= Double(segment.source.lowerBound) && v <= Double(segment.source.upperBound) {
            return Double(segment.destination) + v - Double(segment.source.lowerBound)
        }
        return nil
    }
}
