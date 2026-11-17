/// Finds the boundaries a crop wants to sit on: where a run of the picture changes sharply
/// from one line to the next along most of the crop's side — a panel's border, a window's
/// frame, a card's outline. `GapSnapper` finds uniform lines instead, which a border between
/// two textured areas never is.
public enum EdgeSnapper {
    /// The per-channel difference between neighbouring pixels that counts as a step.
    public static let step = 32

    /// The share of the span that must step for the boundary to count as an edge, so the tops
    /// of a line of text, which step only under its glyphs, don't.
    public static let share = 0.6

    /// The edge nearest `position` within `radius`, nil when there is none. An edge at `c` lies
    /// between line `c - 1` and line `c`, so it is where a crop edge goes: a crop's top or left
    /// edge at `c` starts on line `c`, its bottom or right edge at `c` ends on line `c - 1`.
    public static func edge(
        near position: Int, axis: Axis, in buffer: PixelBuffer, radius: Int, span: Range<Int>
    ) -> Int? {
        for distance in 0...max(radius, 0) {
            for candidate in [position - distance, position + distance]
            where isEdge(at: candidate, axis: axis, in: buffer, span: span) {
                return candidate
            }
        }
        return nil
    }

    /// Whether the boundary before line `boundary` steps along at least `share` of `span`,
    /// clipped to the buffer; false at the buffer's own edges and for a span that misses it.
    public static func isEdge(
        at boundary: Int, axis: Axis, in buffer: PixelBuffer, span: Range<Int>
    )
        -> Bool
    {
        let extent = axis == .horizontal ? buffer.height : buffer.width
        let across = axis == .horizontal ? buffer.width : buffer.height
        guard boundary > 0, boundary < extent else { return false }
        let lower = max(span.lowerBound, 0)
        let upper = min(span.upperBound, across)
        guard lower < upper else { return false }
        var steps = 0
        for i in lower..<upper {
            let a =
                axis == .horizontal ? buffer[x: i, y: boundary - 1] : buffer[x: boundary - 1, y: i]
            let b = axis == .horizontal ? buffer[x: i, y: boundary] : buffer[x: boundary, y: i]
            if abs(Int(a.r) - Int(b.r)) > step || abs(Int(a.g) - Int(b.g)) > step
                || abs(Int(a.b) - Int(b.b)) > step
            {
                steps += 1
            }
        }
        return Double(steps) >= share * Double(upper - lower)
    }
}
