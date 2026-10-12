import CoreGraphics
import ExcerptCore
import Foundation

/// Reads the text in an image and returns its runs, bounds in the image's pixels, top-left
/// origin. The one seam between excerpt and an OCR engine, so everything around it is tested
/// without one.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) throws -> [RecognizedText]
}

/// Why a render can't be read. The description is a sentence about the capture that doesn't name
/// it: `excerpt read` puts the path before it, the app's export alert names the capture.
public enum CaptureTextError: Error, Equatable, LocalizedError {
    /// The render's cuts split it into more regions than `CaptureText.maximumRegions`.
    case tooManyRegions(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyRegions(let count):
            "Its cuts split it into \(LengthText.count(count)) parts to read; text is read from at most \(LengthText.count(CaptureText.maximumRegions))."
        }
    }
}

/// The text of a render, read only from what the render shows, with every cut written in where
/// it was made. The render is the primary's pixels: a cut band is not in it, and a blurred area
/// is only `BlurRenderer`'s blocks, which hold no readable text.
public enum CaptureText {
    /// A part of the render read on its own: one kept span of rows by one kept span of columns,
    /// sliced like the tiles when tall, so a recogniser never sees a seam or its label.
    public struct Region: Equatable, Sendable {
        /// In rendered pixels.
        public let rect: PixelRect
        /// The rendered rows whose runs this region reports, so runs in the rows two slices
        /// share are reported once.
        public let owned: Range<Int>
    }

    /// The most regions one read takes. Each is a recognition pass of its own, so a render cut
    /// into more is refused before any is read rather than recognised for hours.
    public static let maximumRegions = 4_000

    /// The most a region's longer side may be, in multiples of its shorter side, as the
    /// recogniser is shown it. Vision finds nothing on a strip much flatter than this (a short
    /// kept segment below a seam, full width), so such a region is padded first.
    public static let maximumAspect = 8

    /// What the recogniser is shown for a `width`×`height` region: a white canvas whose shorter
    /// side is at least the longer over `maximumAspect`, as far as `maximumPixels` allows, with
    /// the region whole and centred at `content`. A region already within the aspect is its own
    /// canvas.
    public struct Canvas: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// Where the region sits on the canvas, in the canvas's pixels, top-left origin.
        public let content: PixelRect

        /// The most pixels a canvas for a region of `region` pixels may have: four times the
        /// region, or 16 megapixels when that is more. Padding stops there, so a tiny file of a
        /// very wide, very short image can't make a canvas of gigabytes.
        public static func maximumPixels(region: Int) -> Int { max(4 * region, 16_000_000) }

        public init(width regionWidth: Int, height regionHeight: Int) {
            let longer = max(regionWidth, regionHeight)
            let shorter = min(regionWidth, regionHeight)
            let wanted = (longer + CaptureText.maximumAspect - 1) / CaptureText.maximumAspect
            let fits = Self.maximumPixels(region: regionWidth * regionHeight) / longer
            let padded = max(shorter, min(wanted, fits))
            width = regionWidth < regionHeight ? padded : regionWidth
            height = regionWidth < regionHeight ? regionHeight : padded
            content = PixelRect(
                x: (width - regionWidth) / 2, y: (height - regionHeight) / 2, width: regionWidth,
                height: regionHeight)
        }

        /// `piece` drawn at `content` on white; `piece` itself when there is no padding.
        func image(of piece: CGImage) -> CGImage {
            guard width != content.width || height != content.height else { return piece }
            let context = PixelBuffer.makeContext(width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(
                piece,
                in: CGRect(
                    x: content.x, y: height - content.y - content.height, width: content.width,
                    height: content.height))
            return context.makeImage()!
        }
    }

    /// Regions too thin to hold a line of text are not read.
    public static let minimumRegionSide = 8

    /// Every region to read, top to bottom, then left to right.
    public static func regions(of map: RenderMap, scale: Double) -> [Region] {
        let points = Tiling.points(map.renderedWidth, scale: scale)
        let tile = Int((Double(Tiling.tileLength(width: points)) * scale).rounded())
        let overlap = Int((Double(Tiling.overlap) * scale).rounded())
        var regions: [Region] = []
        for rows in map.rows.segments where rows.source.count >= minimumRegionSide {
            let slices = Tiling.spans(length: rows.source.count, tile: tile, overlap: overlap)
            for (slice, owned) in zip(slices, Tiling.ownedBands(slices)) {
                for columns in map.columns.segments where columns.source.count >= minimumRegionSide
                {
                    regions.append(
                        Region(
                            rect: PixelRect(
                                x: columns.destination, y: rows.destination + slice.lowerBound,
                                width: columns.source.count, height: slice.count),
                            owned: (rows.destination + owned.lowerBound)..<(rows.destination
                                + owned.upperBound)))
                }
            }
        }
        return regions
    }

    /// Reads every region of `image`, the render `map` describes, each shown to the recogniser
    /// on its `Canvas`, and writes the text. Throws
    /// `tooManyRegions` before reading any when there are more than `maximumRegions`.
    public static func read(
        _ image: CGImage, map: RenderMap, scale: Double, recognizer: any TextRecognizer
    ) throws -> String {
        precondition(
            image.width == map.renderedWidth && image.height == map.renderedHeight,
            "the map describes this render")
        let regions = regions(of: map, scale: scale)
        guard regions.count <= maximumRegions else {
            throw CaptureTextError.tooManyRegions(regions.count)
        }
        var runs: [RecognizedText] = []
        for region in regions {
            let piece = image.cropping(to: region.rect.cgRect)!
            let canvas = Canvas(width: piece.width, height: piece.height)
            for run in try recognizer.recognize(canvas.image(of: piece)) {
                let bounds = run.bounds.offsetBy(
                    dx: CGFloat(region.rect.x - canvas.content.x),
                    dy: CGFloat(region.rect.y - canvas.content.y))
                if usable(bounds), region.owned.contains(Int(bounds.midY)) {
                    runs.append(RecognizedText(run.string, bounds))
                }
            }
        }
        return compose(runs, map: map, scale: scale) { gutter, rows in
            backgroundChanges(image, gutter: gutter, rows: rows)
        }
    }

    /// Two pixels differ in background when a channel differs by more than this.
    static let backgroundTolerance = 16
    /// The fraction of rows whose two ends of a gutter must differ for the background to change.
    static let backgroundChangedFraction = 0.75

    /// Whether `image`'s background changes across `gutter` over `rows`: the pixels at the
    /// gutter's two ends differ on at least `backgroundChangedFraction` of the rows. Both are
    /// clamped to the image; false when nothing of them is in it.
    public static func backgroundChanges(
        _ image: CGImage, gutter: Range<Int>, rows: Range<Int>
    ) -> Bool {
        let rows = rows.clamped(to: 0..<image.height)
        let columns = gutter.clamped(to: 0..<image.width)
        guard columns.count >= 2, !rows.isEmpty else { return false }
        func column(_ x: Int) -> PixelBuffer {
            PixelBuffer(
                image.cropping(
                    to: CGRect(x: x, y: rows.lowerBound, width: 1, height: rows.count))!)
        }
        let (left, right) = (column(columns.lowerBound), column(columns.upperBound - 1))
        let differing = (0..<rows.count).filter { y in
            let (a, b) = (left[x: 0, y: y], right[x: 0, y: y])
            return [(a.r, b.r), (a.g, b.g), (a.b, b.b)].contains {
                abs(Int($0) - Int($1)) > backgroundTolerance
            }
        }
        return Double(differing.count) >= backgroundChangedFraction * Double(rows.count)
    }

    /// The text of an image with nothing cut: what Capture Text copies.
    public static func read(
        _ image: CGImage, scale: Double, recognizer: any TextRecognizer
    ) throws -> String {
        let map = Renderer.map(
            width: image.width, height: image.height, edits: EditDocument(scale: scale))
        return try read(image, map: map, scale: scale, recognizer: recognizer)
    }

    /// Bounds a run can be placed by: finite, and near enough the image that its middle is an
    /// `Int`. A recogniser's NaN or infinite box is dropped rather than trapping the conversion.
    static func usable(_ bounds: CGRect) -> Bool {
        let values = [bounds.minX, bounds.minY, bounds.width, bounds.height]
        return values.allSatisfy { $0.isFinite && abs($0) <= 1e9 }
    }

    /// `[⋯ 1,240 px hidden]`: the seam's own label, in brackets.
    public static func marker(removedPixels: Int, scale: Double) -> String {
        "[\(SeamLabel.text(removedPixels: removedPixels, scale: scale))]"
    }

    /// The text of `runs` (rendered pixels): lines in reading order, a row cut on its own line
    /// where it was made, and a column cut between the runs either side of it on each line it
    /// splits. A column cut no line spans is written on its own line at the top. Runs whose bounds
    /// aren't `usable` are dropped. Each kept segment's runs are read as `ReadingOrder.blocks`
    /// split by `backgroundChanges`, which never splits by default. Empty when there is neither
    /// text nor a cut.
    public static func compose(
        _ runs: [RecognizedText], map: RenderMap, scale: Double,
        backgroundChanges: ReadingOrder.BackgroundChange = { _, _ in false }
    ) -> String {
        let runs = runs.filter { usable($0.bounds) }
        let columnSegments = map.columns.segments
        func column(_ run: RecognizedText) -> Int {
            columnSegments.lastIndex { Double($0.destination) <= Double(run.bounds.midX) } ?? 0
        }
        var spanned = Set<Int>()
        func write(_ line: TextLine) -> String {
            var text = line.runs[0].string
            for (left, right) in zip(line.runs, line.runs.dropFirst()) {
                let (a, b) = (column(left), column(right))
                if a < b {
                    let end = columnSegments[a].destination + columnSegments[a].source.count
                    let start = columnSegments[b].destination
                    for (index, gap) in map.columns.gaps.enumerated()
                    where gap.destination.lowerBound >= end && gap.destination.upperBound <= start {
                        spanned.insert(index)
                        text += " " + marker(removedPixels: gap.removed, scale: scale)
                    }
                }
                text += " " + right.string
            }
            return text
        }

        var body: [String] = []
        var gaps = map.rows.gaps[...]
        for segment in map.rows.segments {
            while let gap = gaps.first, gap.destination.lowerBound < segment.destination {
                body.append(marker(removedPixels: gap.removed, scale: scale))
                gaps.removeFirst()
            }
            let rows = segment.destination..<(segment.destination + segment.source.count)
            let blocks = ReadingOrder.blocks(
                runs.filter { rows.contains(Int($0.bounds.midY)) },
                backgroundChanges: backgroundChanges)
            body += ReadingOrder.text(blocks: blocks, write: write)
        }
        body += gaps.map { marker(removedPixels: $0.removed, scale: scale) }
        let unspanned = map.columns.gaps.indices.filter { !spanned.contains($0) }.map {
            marker(removedPixels: map.columns.gaps[$0].removed, scale: scale)
        }
        let all = unspanned + body
        return all.isEmpty ? "" : all.joined(separator: "\n") + "\n"
    }
}
