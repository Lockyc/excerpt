import CoreGraphics
import CoreText
import Foundation

/// The look of a recognised run of text, as a text annotation reproduces it: drawn at `origin`
/// in `style` and `color`, its baseline lands on the original's.
public struct MatchedText: Equatable, Sendable {
    /// A text annotation's origin: the top of its line, at the glyph origin that puts the
    /// rendered ink's left edge on the run's (`.left`) or the centre of the flat region around
    /// it (`.centered`).
    public let origin: CGPoint
    public let style: TextStyle
    public let color: AnnotationColor
    /// The colour around the run.
    public let ground: RGBA
    /// The whole pixels holding the run's ink, descenders included.
    public let ink: CGRect

    public init(
        origin: CGPoint, style: TextStyle, color: AnnotationColor, ground: RGBA, ink: CGRect
    ) {
        self.origin = origin
        self.style = style
        self.color = color
        self.ground = ground
        self.ink = ink
    }
}

/// Measures a recognised run of text in a capture — size, weight, monospace or proportional,
/// colour, baseline and alignment — so text typed over it can look native.
public enum TextMatcher {
    /// A pixel within this of the ground on every channel is ground; beyond it, ink. Above
    /// screen-capture noise and the faintest antialiasing, well below any legible text contrast.
    static let groundTolerance = 24

    /// The ink colour is the commonest among pixels at least this fraction as far from the
    /// ground as the farthest: the fully covered pixels, not the antialiased edges, which in
    /// small regular text can outnumber them.
    static let inkColorFraction = 0.75

    /// The lowest band of ink is the descenders' — and the baseline above it — when fewer than
    /// this fraction of the ink's columns, weighed by their coverage there, end in it.
    static let baselineColumnFraction = 0.25

    /// Centred when the run's middle is within this many points of its flat region's middle, and
    /// that region holds ground on both sides of the run.
    static let centredTolerance = 2.0

    /// Steps refining a candidate's size, from its height fit, until its rendered ink is as wide
    /// as the run's. A run is many times wider than it is tall, so in the run's own font its
    /// width pins the size far closer than its height, which rasterising also spreads a fraction
    /// of a pixel past the outlines. Two settle it.
    static let widthSteps = 2

    /// The most a candidate's width fit may differ from its height fit, as a log ratio, for the
    /// width fit to stand. Within it the candidate's widths agree with the run's; beyond it the
    /// run is in another font, and its height, which is what reads as its size, is kept. Above
    /// the few per cent rasterising adds to a small run's height.
    static let widthFitTolerance = 0.08

    /// The typefaces and weights a run is matched against, the first winning a tie.
    static let candidates: [(font: TextFont, bold: Bool)] = [
        (.sans, false), (.sans, true), (.mono, false), (.mono, true),
    ]

    /// The look of `run`, read from `buffer` (the capture at `scale` pixels per point). Nil when
    /// the run's box holds no ink.
    ///
    /// Each candidate font and weight is drawn with the run's string in its colour on its ground,
    /// on its baseline, sized so the rendering's ink is as tall as the run's — read from the
    /// string's own glyphs, so capitals, ascenders and i's dots all measure true — then as wide
    /// (`widthSteps`), and centred on the run's ink. The candidate whose rendering differs least
    /// from the run, coverage for coverage, wins: that weighs stroke thickness and glyph advances
    /// together, where a stroke or spacing statistic alone depends on which letters the run
    /// holds.
    public static func match(_ run: RecognizedText, in buffer: PixelBuffer, scale: Double)
        -> MatchedText?
    {
        guard scale > 0, let ground = ColorSampler.edgeColor(around: run.bounds, in: buffer)
        else { return nil }
        let xs = clamped(run.bounds.minX, run.bounds.maxX, to: buffer.width)
        let ys = clamped(run.bounds.minY, run.bounds.maxY, to: buffer.height)
        guard let color = inkColor(in: buffer, xs: xs, ys: ys, ground: ground),
            let ink = Ink(buffer, xs: xs, ys: ys, ground: ground, color: color)
        else { return nil }
        let string = run.string.components(separatedBy: .newlines).joined(separator: " ")

        var best: (font: TextFont, bold: Bool, size: Double, difference: Double, drawn: Ink)?
        for (font, bold) in candidates {
            let tall = outlineSize(string, font: font, bold: bold, inkHeight: ink.height)
            var size = tall
            for _ in 0..<widthSteps {
                guard let drawn = ink.rendering(string, font: font, bold: bold, pixelSize: size),
                    drawn.width > 0
                else { break }
                size *= ink.width / drawn.width
            }
            if abs(log(size / tall)) > widthFitTolerance { size = tall }
            guard let drawn = ink.rendering(string, font: font, bold: bold, pixelSize: size),
                let aligned = ink.rendering(
                    string, font: font, bold: bold, pixelSize: size,
                    shift: ink.centroidX - Double(ink.xs.lowerBound) - drawn.centroidX)
            else { continue }
            let difference = ink.difference(from: aligned)
            if difference < best?.difference ?? .infinity {
                best = (font, bold, size, difference, aligned)
            }
        }
        guard let best else { return nil }

        let range = TextStyle.pointsRange
        let points = min(max(best.size / scale, range.lowerBound), range.upperBound)
        let font = TextLayout.font(pixelSize: points * scale, font: best.font, bold: best.bold)
        let region = flatRegion(around: ink.columns, rows: ys, in: buffer, ground: ground)
        let regionMid = Double(region.lowerBound + region.upperBound) / 2
        let inkMid = Double(ink.columns.lowerBound + ink.columns.upperBound) / 2
        let grounded =
            region.lowerBound < ink.columns.lowerBound && region.upperBound > ink.columns.upperBound
        let centred = grounded && abs(inkMid - regionMid) <= centredTolerance * scale
        // The renderer puts the glyph origin at `origin.x`; the ink starts one left side-bearing
        // to its right.
        let bearing = CTLineGetBoundsWithOptions(
            TextLayout.line(string, font: font, color: color.cgColor), .useGlyphPathBounds
        ).minX
        return MatchedText(
            origin: CGPoint(
                x: centred ? regionMid : ink.left - Double(bearing),
                y: ink.baseline - Double(CTFontGetAscent(font))),
            style: TextStyle(
                points: points, bold: best.bold, font: best.font,
                alignment: centred ? .centered : .left),
            color: .sampled(fittedColor(color, to: best.drawn, in: buffer, ink: ink)),
            ground: ground,
            ink: CGRect(
                x: ink.columns.lowerBound, y: ink.rows.lowerBound, width: ink.columns.count,
                height: ink.rows.count))
    }

    /// The run's ink colour fitted to `drawn`'s coverage by least squares, each pixel the ground
    /// moved that far toward the ink, when that lies farther from the ground than `sampled`.
    /// Text too thin for any pixel to be wholly covered never shows its colour outright: the
    /// commonest strong pixel is only partly inked, and the fit recovers the full colour.
    static func fittedColor(_ sampled: RGBA, to drawn: Ink, in buffer: PixelBuffer, ink: Ink)
        -> RGBA
    {
        let ground = ink.ground
        var squares = 0.0
        var sums = (r: 0.0, g: 0.0, b: 0.0)
        for (row, y) in ink.ys.enumerated() {
            for (column, x) in ink.xs.enumerated() {
                let a = drawn.cover[row * ink.xs.count + column]
                guard a > 0 else { continue }
                let p = buffer[x: x, y: y]
                squares += a * a
                sums.r += a * (Double(p.r) - Double(ground.r))
                sums.g += a * (Double(p.g) - Double(ground.g))
                sums.b += a * (Double(p.b) - Double(ground.b))
            }
        }
        guard squares > 0 else { return sampled }
        func channel(_ g: UInt8, _ sum: Double) -> UInt8 {
            UInt8(min(max(Double(g) + sum / squares, 0), 255).rounded())
        }
        let fitted = RGBA(
            r: channel(ground.r, sums.r), g: channel(ground.g, sums.g),
            b: channel(ground.b, sums.b), a: 255)
        return distance(fitted, ground) > distance(sampled, ground) ? fitted : sampled
    }

    /// The commonest colour among the pixels of `xs`×`ys` nearly as far from `ground` as the
    /// farthest (`inkColorFraction`), the earliest on ties; nil when every pixel is ground.
    static func inkColor(in buffer: PixelBuffer, xs: Range<Int>, ys: Range<Int>, ground: RGBA)
        -> RGBA?
    {
        let inked = ys.flatMap { y in xs.map { buffer[x: $0, y: y] } }
            .filter { distance($0, ground) > groundTolerance }
        guard let farthest = inked.map({ distance($0, ground) }).max() else { return nil }
        let floor = inkColorFraction * Double(farthest)
        var counts: [RGBA: (count: Int, first: Int)] = [:]
        for p in inked where Double(distance(p, ground)) >= floor {
            let order = counts.count
            counts[p, default: (0, order)].count += 1
        }
        return counts.max {
            ($0.value.count, -$0.value.first) < ($1.value.count, -$1.value.first)
        }?.key
    }

    /// The columns out from `columns` whose pixels over `rows` are all ground: the cell a run
    /// sits in, ending at a gridline, a change of ground or the buffer's edge.
    static func flatRegion(
        around columns: Range<Int>, rows: Range<Int>, in buffer: PixelBuffer, ground: RGBA
    ) -> Range<Int> {
        func flat(_ x: Int) -> Bool {
            rows.allSatisfy { distance(buffer[x: x, y: $0], ground) <= groundTolerance }
        }
        var lower = columns.lowerBound
        while lower > 0, flat(lower - 1) { lower -= 1 }
        var upper = columns.upperBound
        while upper < buffer.width, flat(upper) { upper += 1 }
        return lower..<upper
    }

    /// The pixel size at which `string`'s glyph outlines in `font` rise `inkHeight` above the
    /// baseline. The ratio is re-read at each estimate: the system font's optical sizes move
    /// its ascenders against its cap height.
    static func outlineSize(_ string: String, font: TextFont, bold: Bool, inkHeight: Double)
        -> Double
    {
        var size = 100.0
        for _ in 0..<4 {
            let top = CTLineGetBoundsWithOptions(
                line(string, font: font, bold: bold, pixelSize: size, color: .black),
                .useGlyphPathBounds
            ).maxY
            guard top > 0 else { return size }
            size = inkHeight / (Double(top) / size)
        }
        return size
    }

    /// `string` as annotation text lays it out, in a font made afresh rather than from
    /// `TextCache`: a match tries dozens of fractional sizes no annotation will use, which would
    /// crowd out the fonts a repaint relies on.
    static func line(
        _ string: String, font: TextFont, bold: Bool, pixelSize: Double, color: CGColor
    ) -> CTLine {
        TextLayout.line(
            string, font: TextLayout.makeFont(pixelSize: pixelSize, font: font, bold: bold),
            color: color)
    }

    /// The largest per-channel difference between two colours.
    static func distance(_ a: RGBA, _ b: RGBA) -> Int {
        max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
    }

    /// The whole pixels from `lower` to `upper`, rounded outward, within `0..<extent`.
    static func clamped(_ lower: CGFloat, _ upper: CGFloat, to extent: Int) -> Range<Int> {
        guard lower.isFinite, upper.isFinite else { return 0..<0 }
        let from = Int(min(max(lower.rounded(.down), 0), CGFloat(extent)))
        let to = Int(min(max(upper.rounded(.up), CGFloat(from)), CGFloat(extent)))
        return from..<to
    }

    /// The ink in a box: how much of it each pixel carries, and where it lies.
    struct Ink {
        let ground: RGBA
        let color: RGBA
        let xs: Range<Int>
        let ys: Range<Int>
        /// How far each pixel of the box goes from the ground toward the ink, 0 to 1, top row
        /// first, measured on the channel where the two differ most.
        let cover: [Double]
        /// The columns and rows holding ink, in the buffer's pixels.
        let columns: Range<Int>
        let rows: Range<Int>
        /// The ink's top, to sub-pixel precision.
        let top: Double
        /// The bottom of the non-descending glyphs' ink, to sub-pixel precision: the lowest row
        /// in which at least `baselineColumnFraction` of the ink's columns end, each counted by
        /// its coverage there. Fewer end lower, in the descenders, where only a stem or a tail
        /// reaches; round glyphs' overshoot below the baseline ends faintly, so it counts for
        /// little. The coverage of the ink ending in the row places the baseline within it, as
        /// the topmost ink's coverage places the top.
        let baseline: Double
        /// The ink's left and right edges, to sub-pixel precision, placed within their columns
        /// by their coverage.
        let left: Double
        let right: Double

        var height: Double { baseline - top }
        var width: Double { right - left }

        /// The ink of `xs`×`ys` in `buffer`; nil when the box holds none.
        init?(_ buffer: PixelBuffer, xs: Range<Int>, ys: Range<Int>, ground: RGBA, color: RGBA) {
            guard !xs.isEmpty, !ys.isEmpty else { return nil }
            let channels: [(RGBA) -> UInt8] = [{ $0.r }, { $0.g }, { $0.b }]
            let channel = channels.max {
                abs(Int($0(color)) - Int($0(ground))) < abs(Int($1(color)) - Int($1(ground)))
            }!
            let span = Double(channel(color)) - Double(channel(ground))
            guard span != 0 else { return nil }
            let width = xs.count
            var cover = [Double](repeating: 0, count: width * ys.count)
            for (row, y) in ys.enumerated() {
                for (column, x) in xs.enumerated() {
                    let p = buffer[x: x, y: y]
                    guard TextMatcher.distance(p, ground) > TextMatcher.groundTolerance else {
                        continue
                    }
                    let c = (Double(channel(p)) - Double(channel(ground))) / span
                    cover[row * width + column] = min(max(c, 0), 1)
                }
            }
            func at(_ column: Int, _ row: Int) -> Double { cover[row * width + column] }

            var tops: [Int: Int] = [:]
            var bottoms: [Int: Int] = [:]
            for column in 0..<width {
                let rows = (0..<ys.count).filter { at(column, $0) > 0 }
                if let first = rows.first, let last = rows.last {
                    tops[column] = first
                    bottoms[column] = last
                }
            }
            guard let firstColumn = tops.keys.min(), let lastColumn = tops.keys.max() else {
                return nil
            }
            var ending: [Int: Double] = [:]
            for (column, row) in bottoms { ending[row, default: 0] += at(column, row) }
            let needed = TextMatcher.baselineColumnFraction * ending.values.reduce(0, +)
            let baseRow =
                ending.keys.sorted(by: >).first { ending[$0]! >= needed }
                ?? ending.max { $0.value < $1.value }!.key
            let baseCover = bottoms.filter { $0.value == baseRow }.keys.map { at($0, baseRow) }
                .max()!
            let topRow = tops.values.min()!
            let topCover = tops.filter { $0.value == topRow }.keys.map { at($0, topRow) }.max()!

            self.ground = ground
            self.color = color
            self.xs = xs
            self.ys = ys
            self.cover = cover
            columns = (xs.lowerBound + firstColumn)..<(xs.lowerBound + lastColumn + 1)
            rows = (ys.lowerBound + topRow)..<(ys.lowerBound + bottoms.values.max()! + 1)
            top = Double(ys.lowerBound + topRow) + 1 - topCover
            baseline = Double(ys.lowerBound + baseRow) + baseCover
            func peak(_ column: Int) -> Double { (0..<ys.count).map { at(column, $0) }.max()! }
            left = Double(xs.lowerBound + firstColumn) + 1 - peak(firstColumn)
            right = Double(xs.lowerBound + lastColumn) + peak(lastColumn)
        }

        /// The coverage-weighted mean column, in the buffer's pixels: where the ink sits across,
        /// to a fraction of a pixel.
        var centroidX: Double {
            let width = xs.count
            var sum = 0.0
            var weighted = 0.0
            for (i, c) in cover.enumerated() where c > 0 {
                sum += c
                weighted += c * (Double(i % width) + 0.5)
            }
            return Double(xs.lowerBound) + weighted / max(sum, .leastNonzeroMagnitude)
        }

        /// `string` drawn in `color` on `ground` over a copy of this box, on this ink's baseline
        /// with its glyphs' left edge on this ink's moved `shift` pixels right, and measured as
        /// this ink is, in the copy's pixels. Nil when nothing of it lands in the box.
        func rendering(
            _ string: String, font: TextFont, bold: Bool, pixelSize: Double, shift: Double = 0
        ) -> Ink? {
            let line = TextMatcher.line(
                string, font: font, bold: bold, pixelSize: pixelSize, color: color.cgColor)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let context = PixelBuffer.makeContext(width: xs.count, height: ys.count)
            context.setFillColor(ground.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: xs.count, height: ys.count))
            TextLayout.draw(
                line,
                at: CGPoint(
                    x: Double(columns.lowerBound - xs.lowerBound) - Double(glyphs.minX) + shift,
                    y: Double(ys.upperBound) - baseline),
                in: context)
            return Ink(
                PixelBuffer(context.makeImage()!), xs: 0..<xs.count, ys: 0..<ys.count,
                ground: ground, color: color)
        }

        /// How far `other`, over a box the same size, is from this ink: their coverages'
        /// summed difference over this ink's total.
        func difference(from other: Ink) -> Double {
            zip(cover, other.cover).map { abs($0 - $1) }.reduce(0, +)
                / max(cover.reduce(0, +), 1)
        }
    }
}
