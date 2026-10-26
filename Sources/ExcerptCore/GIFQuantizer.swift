/// Reduces a frame's colours to a GIF colour table: median cut over the distinct colours, then
/// each pixel to its nearest table entry. No dithering — screen content is flat colour, and
/// dithering defeats both the frame diff and LZW.
public enum GIFQuantizer {
    /// Up to `maximum` colours for `pixels`: the distinct colours themselves when there are no
    /// more than `maximum`, otherwise the pixel-weighted mean of each median-cut box.
    public static func palette(_ pixels: [RGBA], maximum: Int) -> [RGBA] {
        precondition(maximum >= 1)
        var counts: [UInt32: Int] = [:]
        for pixel in pixels { counts[key(pixel), default: 0] += 1 }
        if counts.count <= maximum { return counts.keys.sorted().map(color) }

        var colours = counts.map { Swatch(key: $0.key, count: $0.value) }
        var boxes = [Box(colours[...], range: 0..<colours.count)]
        while boxes.count < maximum,
            let widest = boxes.indices.max(by: { boxes[$0].spread < boxes[$1].spread }),
            boxes[widest].spread > 0
        {
            let box = boxes[widest]
            let channel = box.channel
            colours[box.range].sort { $0.channels[channel] < $1.channels[channel] }
            let total = colours[box.range].reduce(0) { $0 + $1.count }
            var split = box.range.lowerBound
            var seen = 0
            while split < box.range.upperBound - 1, seen + colours[split].count <= total / 2 {
                seen += colours[split].count
                split += 1
            }
            split = max(split, box.range.lowerBound + 1)
            let lower = box.range.lowerBound..<split
            let upper = split..<box.range.upperBound
            boxes[widest] = Box(colours[lower], range: lower)
            boxes.append(Box(colours[upper], range: upper))
        }
        return boxes.map { box in
            var sums = [Int](repeating: 0, count: 4)
            var total = 0
            for swatch in colours[box.range] {
                for channel in 0..<4 {
                    sums[channel] += Int(swatch.channels[channel]) * swatch.count
                }
                total += swatch.count
            }
            let mean = sums.map { UInt8(($0 + total / 2) / total) }
            return RGBA(r: mean[0], g: mean[1], b: mean[2], a: mean[3])
        }
    }

    /// Each pixel's index of its nearest `palette` colour by squared distance; a colour is
    /// searched for once, however many pixels share it.
    public static func index(_ pixels: [RGBA], into palette: [RGBA]) -> [UInt8] {
        precondition(!palette.isEmpty && palette.count <= 256)
        var cache: [UInt32: UInt8] = [:]
        for (index, colour) in palette.enumerated().reversed() { cache[key(colour)] = UInt8(index) }
        return pixels.map { pixel in
            let k = key(pixel)
            if let hit = cache[k] { return hit }
            var best = 0
            var bestDistance = Int.max
            for (index, colour) in palette.enumerated() {
                let dr = Int(colour.r) - Int(pixel.r)
                let dg = Int(colour.g) - Int(pixel.g)
                let db = Int(colour.b) - Int(pixel.b)
                let da = Int(colour.a) - Int(pixel.a)
                let distance = dr * dr + dg * dg + db * db + da * da
                if distance < bestDistance {
                    best = index
                    bestDistance = distance
                }
            }
            cache[k] = UInt8(best)
            return UInt8(best)
        }
    }

    static func key(_ c: RGBA) -> UInt32 {
        UInt32(c.r) << 24 | UInt32(c.g) << 16 | UInt32(c.b) << 8 | UInt32(c.a)
    }

    static func color(_ key: UInt32) -> RGBA {
        RGBA(
            r: UInt8(truncatingIfNeeded: key >> 24), g: UInt8(truncatingIfNeeded: key >> 16),
            b: UInt8(truncatingIfNeeded: key >> 8), a: UInt8(truncatingIfNeeded: key))
    }

    /// A distinct colour and how many pixels carry it.
    private struct Swatch {
        let channels: SIMD4<UInt8>
        let count: Int

        init(key: UInt32, count: Int) {
            let c = GIFQuantizer.color(key)
            channels = SIMD4(c.r, c.g, c.b, c.a)
            self.count = count
        }
    }

    /// A run of `Swatch`es and its widest channel.
    private struct Box {
        let range: Range<Int>
        let channel: Int
        let spread: Int

        init(_ swatches: ArraySlice<Swatch>, range: Range<Int>) {
            var low = SIMD4<UInt8>(repeating: 255)
            var high = SIMD4<UInt8>(repeating: 0)
            for swatch in swatches {
                low = pointwiseMin(low, swatch.channels)
                high = pointwiseMax(high, swatch.channels)
            }
            let spreads = (0..<4).map { Int(high[$0]) - Int(low[$0]) }
            channel = spreads.indices.max { spreads[$0] < spreads[$1] }!
            spread = spreads[channel]
            self.range = range
        }
    }
}
