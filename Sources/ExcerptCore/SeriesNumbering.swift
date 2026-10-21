/// Step numbering across a series: each capture's first step follows the last step of the
/// capture before it, unless the capture restarts at 1.
public enum SeriesNumbering {
    /// Each capture's first step number, from its step count and whether it restarts. A capture
    /// with no steps gets 1, so renumbering never changes a document that has nothing to number.
    public static func firstSteps(stepCounts: [Int], restarts: [Bool]) -> [Int] {
        precondition(stepCounts.count == restarts.count)
        var next = 1
        return zip(stepCounts, restarts).map { count, restart in
            if restart { next = 1 }
            let first = next
            next += count
            return count == 0 ? 1 : first
        }
    }
}
