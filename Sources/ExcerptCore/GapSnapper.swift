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
        let extent = axis == .horizontal ? buffer.height : buffer.width
        let start = min(max(position, 0), extent - 1)
        for distance in 0...radius {
            for candidate in [start - distance, start + distance]
            where (0..<extent).contains(candidate)
                && isUniform(line: candidate, axis: axis, in: buffer, tolerance: tolerance)
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
        let first = axis == .horizontal ? buffer[x: 0, y: line] : buffer[x: line, y: 0]
        for i in 1..<count {
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
