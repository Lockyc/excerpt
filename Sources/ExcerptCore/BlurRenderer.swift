import CoreGraphics

/// The destructive blur. Rects that overlap, touch or lie closer than a minimum block
/// (`minimumBlock`) on both axes form one group, pixelated together on one
/// grid aligned to the group's bounding box, in blocks sized by `blockPixels` from that box: at
/// least `blockPoints` on a side and at least half its shorter side. So any text a group covers
/// spans at most about two blocks across its height, however large it is drawn and however many
/// thin or nested rects it is drawn with. Blocks fill only the group's rects; pixels outside
/// every rect are untouched. Every block takes its average colour shifted by seeded noise, so the
/// covered content cannot be read from the output; pixelation defeats reading, not
/// candidate-matching of short known strings. Blocks are read from the original pixels and
/// seeded from the document salt and the group's rects, so identical edits render identical
/// pixels.
public enum BlurRenderer {
    public static let blockPoints = 12.0
    /// The most a block's channel moves from its average, either way.
    public static let noiseAmplitude = 24
    /// Blocks never shrink below this, whatever the scale.
    static let minimumBlockPixels = 12

    /// `salt` is the document's random value: it keeps the noise from being recomputed from the
    /// rects alone, which are readable off the output.
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
        let flip = CanvasFlip(height: image.height)
        for group in groups(regions, reach: minimumBlock(scale: scale)) {
            let box = boundingBox(group)
            guard let piece = image.cropping(to: box.cgRect) else {
                preconditionFailure("clamped blur group lies inside the image")
            }
            let blocks = pixelate(
                PixelBuffer(piece), block: blockPixels(for: box, scale: scale),
                seed: seed(group, salt: salt))
            context.saveGState()
            context.clip(to: group.map { flip.rect($0.cgRect) })
            context.draw(blocks.makeImage(), in: flip.rect(box.cgRect))
            context.restoreGState()
        }
        return context.makeImage()!
    }

    /// The connected sets of `regions` whose gap is under `reach` pixels on both axes (so
    /// overlapping and touching ones, corners included, at any `reach` of 1 or more), each in
    /// input order, ordered by their first member. A sweep down the rows compares each region
    /// only with those still within `reach` of its top.
    static func groups(_ regions: [PixelRect], reach: Int) -> [[PixelRect]] {
        var parent = Array(regions.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var active: [Int] = []
        for i in regions.indices.sorted(by: { regions[$0].y < regions[$1].y }) {
            let r = regions[i]
            active.removeAll { regions[$0].y + regions[$0].height + reach <= r.y }
            for j in active
            where regions[j].x < r.x + r.width + reach
                && r.x < regions[j].x + regions[j].width + reach
            {
                parent[root(j)] = root(i)
            }
            active.append(i)
        }
        var order: [Int] = []
        var members: [Int: [PixelRect]] = [:]
        for i in regions.indices {
            let key = root(i)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(regions[i])
        }
        return order.map { members[$0]! }
    }

    static func boundingBox(_ group: [PixelRect]) -> PixelRect {
        let left = group.map(\.x).min()!
        let top = group.map(\.y).min()!
        let right = group.map { $0.x + $0.width }.max()!
        let bottom = group.map { $0.y + $0.height }.max()!
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The side of a group's blocks, in pixels, from its bounding box `region`: `blockPoints` at
    /// `scale` (never under `minimumBlockPixels`), or half the box's shorter side when larger.
    static func blockPixels(for region: PixelRect, scale: Double) -> Int {
        max(minimumBlock(scale: scale), (min(region.width, region.height) + 1) / 2)
    }

    /// The smallest block, in pixels: `blockPoints` at `scale`, never under `minimumBlockPixels`.
    /// Blurs closer than this pixelate as one group.
    static func minimumBlock(scale: Double) -> Int {
        max(minimumBlockPixels, Int((blockPoints * scale).rounded(.up)))
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

    /// Mixes the salt and every field of every rect of the group through SplitMix64's finalizer.
    static func seed(_ group: [PixelRect], salt: UInt64) -> UInt64 {
        var state = salt
        for region in group {
            for field in [region.x, region.y, region.width, region.height] {
                var mixer = SplitMix64(state: state ^ UInt64(truncatingIfNeeded: field))
                state = mixer.next()
            }
        }
        return state
    }
}
