import CoreGraphics

/// The destructive blur. Each rect is pixelated into blocks at least `blockPoints` on a side, and
/// every block takes its average colour shifted by seeded noise, so the covered content can't be
/// recovered by matching rendered candidates against the blocks. Blocks are read from the
/// original pixels and seeded from the rect, so identical edits render identical pixels.
public enum BlurRenderer {
    public static let blockPoints = 12.0
    /// The most a block's channel moves from its average, either way.
    public static let noiseAmplitude = 24

    public static func apply(_ rects: [CGRect], to image: CGImage, scale: Double) -> CGImage {
        let regions = rects.compactMap { rect -> PixelRect? in
            let r = rect.standardized.integral
            guard abs(r.minX) < 1e9, abs(r.minY) < 1e9, r.width < 1e9, r.height < 1e9 else {
                return nil
            }
            return PixelRect(
                x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height)
            )
            .clamped(width: image.width, height: image.height)
        }
        guard !regions.isEmpty else { return image }
        let context = PixelBuffer.makeContext(width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let block = max(1, Int((blockPoints * scale).rounded(.up)))
        for region in regions {
            guard let piece = image.cropping(to: region.cgRect) else { continue }
            let blocks = pixelate(PixelBuffer(piece), block: block, seed: seed(region))
            context.draw(
                blocks.makeImage(), in: CanvasFlip(height: image.height).rect(region.cgRect))
        }
        return context.makeImage()!
    }

    /// Splits `length` into blocks no shorter than `block` (one block when `length` is shorter):
    /// the boundaries, from 0 to `length`.
    static func boundaries(length: Int, block: Int) -> [Int] {
        let count = max(1, length / block)
        return (0...count).map { $0 * length / count }
    }

    static func pixelate(_ buffer: PixelBuffer, block: Int, seed: UInt64) -> PixelBuffer {
        var out = buffer
        var random = SplitMix64(state: seed)
        let xs = boundaries(length: buffer.width, block: block)
        let ys = boundaries(length: buffer.height, block: block)
        for (top, bottom) in zip(ys, ys.dropFirst()) {
            for (left, right) in zip(xs, xs.dropFirst()) {
                var sums = [0, 0, 0, 0]
                for y in top..<bottom {
                    for x in left..<right {
                        let i = (y * buffer.width + x) * 4
                        for c in 0..<4 { sums[c] += Int(buffer.bytes[i + c]) }
                    }
                }
                let count = (bottom - top) * (right - left)
                let alpha = sums[3] / count
                var colour = [0, 0, 0, alpha]
                for c in 0..<3 {
                    let noise = Int(random.next() % UInt64(2 * noiseAmplitude + 1)) - noiseAmplitude
                    colour[c] = min(max(sums[c] / count + noise, 0), alpha)
                }
                for y in top..<bottom {
                    for x in left..<right {
                        let i = (y * buffer.width + x) * 4
                        for c in 0..<4 { out.bytes[i + c] = UInt8(colour[c]) }
                    }
                }
            }
        }
        return out
    }

    static func seed(_ region: PixelRect) -> UInt64 {
        UInt64(truncatingIfNeeded: region.x) << 48 ^ UInt64(truncatingIfNeeded: region.y) << 32
            ^ UInt64(truncatingIfNeeded: region.width) << 16
            ^ UInt64(truncatingIfNeeded: region.height)
    }
}
