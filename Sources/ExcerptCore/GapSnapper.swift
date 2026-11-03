/// Snaps a cut's edge to a line the cut can't bisect: the nearest whole row (or column) that is
/// one colour within `tolerance`, which is whitespace or a gridline. That keeps cuts from
/// splitting a line of text or a table row.
public enum GapSnapper {
    /// How far an edge looks for a line to snap to, in points.
    public static let radiusPoints = 12.0

    /// `radiusPoints` in original pixels at `scale` (original pixels per point), rounded to the
    /// nearest whole pixel.
    public static func radius(scale: Double) -> Int { Int((radiusPoints * scale).rounded()) }

    public static func snap(
        _ position: Int, axis: Axis, in buffer: PixelBuffer, radius: Int, tolerance: UInt8 = 6
    ) -> Int {
        let across = axis == .horizontal ? buffer.width : buffer.height
        return snap(
            position, axis: axis, in: buffer, radius: radius, span: 0..<across,
            tolerance: tolerance)
    }

    /// As `snap`, but a line counts as uniform if it is one colour across `span` only (clipped
    /// to the buffer): a row inside one table cell, not the whole image width. A `span` that
    /// misses the buffer finds no line and keeps the (clamped) position.
    public static func snap(
        _ position: Int, axis: Axis, in buffer: PixelBuffer, radius: Int, span: Range<Int>,
        tolerance: UInt8 = 6
    ) -> Int {
        let extent = axis == .horizontal ? buffer.height : buffer.width
        let start = min(max(position, 0), extent - 1)
        for distance in 0...radius {
            for candidate in [start - distance, start + distance]
            where (0..<extent).contains(candidate)
                && isUniform(
                    line: candidate, axis: axis, in: buffer, span: span, tolerance: tolerance)
            {
                return candidate
            }
        }
        return start
    }

    public static func isUniform(line: Int, axis: Axis, in buffer: PixelBuffer, tolerance: UInt8)
        -> Bool
    {
        let count = axis == .horizontal ? buffer.width : buffer.height
        return isUniform(line: line, axis: axis, in: buffer, span: 0..<count, tolerance: tolerance)
    }

    /// Whether the line is one colour within `tolerance` across `span`, clipped to the buffer;
    /// false when no part of `span` lies in it.
    public static func isUniform(
        line: Int, axis: Axis, in buffer: PixelBuffer, span: Range<Int>, tolerance: UInt8
    ) -> Bool {
        let count = axis == .horizontal ? buffer.width : buffer.height
        let lower = max(span.lowerBound, 0)
        let upper = min(span.upperBound, count)
        guard lower < upper else { return false }
        let first = axis == .horizontal ? buffer[x: lower, y: line] : buffer[x: line, y: lower]
        for i in (lower + 1)..<upper {
            let pixel = axis == .horizontal ? buffer[x: i, y: line] : buffer[x: line, y: i]
            if abs(Int(pixel.r) - Int(first.r)) > Int(tolerance)
                || abs(Int(pixel.g) - Int(first.g)) > Int(tolerance)
                || abs(Int(pixel.b) - Int(first.b)) > Int(tolerance)
            {
                return false
            }
        }
        return true
    }
}
