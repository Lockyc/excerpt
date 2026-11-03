import CoreGraphics

/// Reads colours out of a `PixelBuffer`: the pixel under a point, and the ground around a rect.
public enum ColorSampler {
    /// The pixel containing `p`, or nil outside the buffer.
    public static func pixel(at p: CGPoint, in buffer: PixelBuffer) -> RGBA? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let x = Int(p.x.rounded(.down))
        let y = Int(p.y.rounded(.down))
        guard x >= 0, y >= 0, x < buffer.width, y < buffer.height else { return nil }
        return buffer[x: x, y: y]
    }

    /// The most common colour on the one-pixel ring just outside `rect` (rounded outward to
    /// whole pixels), counting only in-buffer pixels. A pixel within `tolerance` per channel of
    /// an earlier bucket counts toward it, so antialiasing doesn't split a ground; ties go to
    /// the first bucket in ring order (top edge left to right, right edge, bottom, left). The
    /// result is the bucket's first colour. Nil when no ring pixel lies in the buffer.
    public static func edgeColor(
        around rect: CGRect, in buffer: PixelBuffer, tolerance: UInt8 = 6
    ) -> RGBA? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite
        else { return nil }
        let minX = wholePixel(rect.minX, .down)
        let minY = wholePixel(rect.minY, .down)
        let maxX = wholePixel(rect.maxX, .up)
        let maxY = wholePixel(rect.maxY, .up)

        var buckets: [(color: RGBA, count: Int)] = []
        func take(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < buffer.width, y < buffer.height else { return }
            let c = buffer[x: x, y: y]
            if let i = buckets.firstIndex(where: { near($0.color, c, tolerance) }) {
                buckets[i].count += 1
            } else {
                buckets.append((c, 1))
            }
        }

        // The ring's ranges are clipped to the buffer, so a rect far outside walks nothing.
        func clipped(_ lower: Int, _ upper: Int, to limit: Int) -> Range<Int> {
            let low = max(lower, 0)
            let high = min(upper, limit)
            return low < high ? low..<high : 0..<0
        }
        let xs = clipped(minX - 1, maxX + 1, to: buffer.width)
        let ys = clipped(minY, maxY, to: buffer.height)
        for x in xs { take(x, minY - 1) }
        for y in ys { take(maxX, y) }
        for x in xs { take(x, maxY) }
        for y in ys { take(minX - 1, y) }
        return buckets.reduce(nil as (color: RGBA, count: Int)?) { best, b in
            guard let best else { return b }
            return b.count > best.count ? b : best
        }?.color
    }

    /// `v` rounded by `rule` to a whole pixel. Far past any buffer a coordinate means the same
    /// as 1e9 (nothing in range), and NaN is 0, so the Int conversion never traps.
    static func wholePixel(_ v: CGFloat, _ rule: FloatingPointRoundingRule) -> Int {
        guard !v.isNaN else { return 0 }
        return Int(min(max(Double(v.rounded(rule)), -1e9), 1e9))
    }

    private static func near(_ a: RGBA, _ b: RGBA, _ t: UInt8) -> Bool {
        func d(_ x: UInt8, _ y: UInt8) -> Bool { (x > y ? x - y : y - x) <= t }
        return d(a.r, b.r) && d(a.g, b.g) && d(a.b, b.b) && d(a.a, b.a)
    }
}
