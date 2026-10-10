import Foundation

/// Which way a cut runs across the image. A `horizontal` cut is a horizontal band: it removes
/// rows, so the image gets shorter. A `vertical` cut removes columns, so it gets narrower.
public enum Axis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A band removed from the original image, in original pixels: `lower` is the first removed
/// line, `upper` is one past the last.
public struct Cut: Codable, Hashable, Sendable {
    public var axis: Axis
    public var lower: Int
    public var upper: Int

    public init(axis: Axis, lower: Int, upper: Int) {
        self.axis = axis
        self.lower = lower
        self.upper = upper
    }
}

public enum CutSet {
    /// The removed bands on one axis: clamped to `0..<extent`, empty or inverted bands dropped,
    /// sorted, with overlapping or touching bands merged. A merged band that would remove the
    /// whole extent is dropped, because an image must keep at least one line.
    public static func normalized(_ cuts: [Cut], axis: Axis, extent: Int) -> [Range<Int>] {
        let clamped =
            cuts
            .filter { $0.axis == axis }
            .map { cut -> Range<Int> in
                // Both bounds are pinned inside 0...extent so a band wholly outside the image
                // collapses to an empty range instead of an invalid one.
                let lo = min(max(0, cut.lower), extent)
                let hi = min(extent, max(cut.upper, lo))
                return lo..<hi
            }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for band in clamped {
            if let last = merged.last, band.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, band.upperBound)
            } else {
                merged.append(band)
            }
        }
        return merged.filter { $0 != 0..<extent }
    }
}
