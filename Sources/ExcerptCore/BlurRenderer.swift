import CoreGraphics

/// The destructive blur. Each rect is pixelated into blocks at least `blockPoints` on a side, and
/// every block takes its average colour shifted by seeded noise, so the covered content cannot be
/// read from the output; pixelation defeats reading, not candidate-matching of short known
/// strings. Blocks are read from the original pixels and seeded from the document salt and the
/// rect, so identical edits render identical pixels.
public enum BlurRenderer {
    public static let blockPoints = 12.0
    /// The most a block's channel moves from its average, either way.
    public static let noiseAmplitude = 24
    /// Blocks never shrink below this, whatever the scale.
    static let minimumBlockPixels = 12

    /// `salt` is the document's random value: it keeps the noise from being recomputed from the
    /// rect alone, which is readable off the output.
    public static func apply(
        _ rects: [CGRect], to image: CGImage, scale: Double, salt: UInt64
    ) -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let regions = rects.compactMap { rect -> PixelRect? in
            precondition(
                [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                "blur rect must be finite")
            let r = rect.standardized.intersection(bounds).integral
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            return PixelRect(
                x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height))
        }
        guard !regions.isEmpty else { return image }
        let context = PixelBuffer.makeContext(width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        // Copy, not source-over: a translucent block would otherwise show the detail beneath it.
        context.setBlendMode(.copy)
        let block = max(minimumBlockPixels, Int((blockPoints * scale).rounded(.up)))
        for region in regions {
            guard let piece = image.cropping(to: region.cgRect) else {
                preconditionFailure("clamped blur region lies inside the image")
            }
            let blocks = pixelate(PixelBuffer(piece), block: block, seed: seed(region, salt: salt))
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
                    colour[c] = reflected(sums[c] / count + noise, upTo: alpha)
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

    /// Folds `value` back into 0...`upper` at either end, so a near-white or near-black average
    /// is still moved by the noise instead of being clamped onto the bound.
    static func reflected(_ value: Int, upTo upper: Int) -> Int {
        let folded = value < 0 ? -value : (value > upper ? 2 * upper - value : value)
        return min(max(folded, 0), upper)
    }

    /// Mixes the salt and every field of the rect through SplitMix64's finalizer.
    static func seed(_ region: PixelRect, salt: UInt64) -> UInt64 {
        var state = salt
        for field in [region.x, region.y, region.width, region.height] {
            var mixer = SplitMix64(state: state ^ UInt64(truncatingIfNeeded: field))
            state = mixer.next()
        }
        return state
    }
}
