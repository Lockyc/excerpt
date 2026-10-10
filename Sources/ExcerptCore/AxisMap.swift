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

    /// Which edge of a gap a position inside a removed band lands on: `after` for the leading
    /// edge of a shape (it starts where content resumes), `before` for its trailing edge,
    /// `middle` for a lone point.
    public enum Bias: Sendable {
        case before
        case after
        case middle
    }

    public let extent: Int
    /// The removed bands, normalised, in the order of `gaps`.
    public let bands: [Range<Int>]
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
        self.extent = extent
        self.bands = bands
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

    /// The rendered position of any original position: a kept position maps as `map` does; one
    /// inside a removed band lands on that band's gap at the edge `bias` names; one off the image
    /// continues past the nearer edge, so a shape running off a crop is clipped, not dropped.
    public func place(_ v: Double, bias: Bias) -> Double {
        for (band, gap) in zip(bands, gaps) {
            let lower = Double(band.lowerBound)
            let upper = Double(band.upperBound)
            switch bias {
            case .after where v >= lower && v < upper: return Double(gap.destination.upperBound)
            case .before where v > lower && v <= upper: return Double(gap.destination.lowerBound)
            case .middle where v > lower && v < upper:
                return Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            default: continue
            }
        }
        if let mapped = map(v) { return mapped }
        return v <= 0 ? v : Double(renderedLength) + v - Double(extent)
    }

    /// The original position shown at rendered position `r`: through its segment when kept; the
    /// nearer side of the removed band when `r` is on a gap; continued past the edge when off the
    /// image.
    public func unmap(_ r: Double) -> Double {
        for segment in segments {
            let start = Double(segment.destination)
            if r >= start && r <= start + Double(segment.source.count) {
                return Double(segment.source.lowerBound) + r - start
            }
        }
        for (band, gap) in zip(bands, gaps)
        where r >= Double(gap.destination.lowerBound) && r <= Double(gap.destination.upperBound) {
            let middle = Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            return Double(r < middle ? band.lowerBound : band.upperBound)
        }
        return r <= 0 ? r : Double(extent) + r - Double(renderedLength)
    }

    /// Whether `lower...upper` lies wholly inside one removed band.
    public func isRemoved(_ lower: Double, _ upper: Double) -> Bool {
        bands.contains { Double($0.lowerBound) <= lower && upper <= Double($0.upperBound) }
    }
}
