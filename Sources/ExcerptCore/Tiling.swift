/// How a tall image is cut into overlapping slices, so each slice is small enough to read and
/// every line of text lies whole in at least one of them.
public enum Tiling {
    /// The least any two neighbouring slices share. A line of text no taller than this appears
    /// whole in at least one slice.
    public static let overlap = 100

    /// The spans of `0..<length` the slices cover. A length up to `fits` is one span. A longer
    /// one is cut into spans exactly `tile` long, each starting `tile - overlap` after the one
    /// before, with the last pulled back to end at `length`, so it shares more than `overlap`
    /// with its neighbour and never less. Empty for a length of zero or less.
    public static func spans(
        length: Int, tile: Int, overlap: Int = overlap, fits: Int? = nil
    ) -> [Range<Int>] {
        let fits = fits ?? tile
        precondition(tile > overlap && overlap >= 0 && fits >= tile, "tile geometry")
        guard length > 0 else { return [] }
        guard length > fits else { return [0..<length] }
        let stride = tile - overlap
        let count = (length - overlap + stride - 1) / stride
        return (0..<count).map { i in
            let start = i == count - 1 ? length - tile : i * stride
            return start..<(start + tile)
        }
    }

    /// The part of each span that owns what lies there: the spans' common rows split at their
    /// midpoint, so the bands partition the whole length. Anything no taller than the overlap
    /// whose middle lies in a span's band lies wholly inside that span.
    public static func ownedBands(_ spans: [Range<Int>]) -> [Range<Int>] {
        spans.indices.map { i in
            let lower =
                i == 0 ? spans[i].lowerBound : (spans[i].lowerBound + spans[i - 1].upperBound) / 2
            let upper =
                i == spans.count - 1
                ? spans[i].upperBound : (spans[i + 1].lowerBound + spans[i].upperBound) / 2
            return lower..<upper
        }
    }
}
