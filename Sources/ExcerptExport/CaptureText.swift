import CoreGraphics
import ExcerptCore
import Foundation

/// Reads the text in an image and returns its runs, bounds in the image's pixels, top-left
/// origin. The one seam between excerpt and an OCR engine, so everything around it is tested
/// without one.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) throws -> [RecognizedText]
}

/// The text of an image in reading order: what Capture Text copies.
public enum CaptureText {
    /// A part of the image read on its own: the full width by one slice of the rows, so a tall
    /// image is read in pieces the recogniser handles well.
    public struct Region: Equatable, Sendable {
        /// In the image's pixels.
        public let rect: PixelRect
        /// The rows whose runs this region reports, so runs in the rows two slices share are
        /// reported once.
        public let owned: Range<Int>
    }

    /// The most a region's longer side may be, in multiples of its shorter side, as the
    /// recogniser is shown it. Vision finds nothing on a strip much flatter than this (a full
    /// width selection a line tall), so such a region is padded first.
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
        /// region, or 16 megapixels when that is more. Padding stops there, so a very wide, very
        /// short image can't make a canvas of gigabytes.
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

    /// How tall a region is sliced, in points, and the tallest left whole. Vision misses small
    /// text in a region much taller than this.
    public static let sliceLength = 1_500
    public static let wholeLength = 1_568

    /// An image too thin to hold a line of text is not read.
    public static let minimumRegionSide = 8

    /// Every region to read of a `width`×`height` image, top to bottom.
    public static func regions(width: Int, height: Int, scale: Double) -> [Region] {
        guard width >= minimumRegionSide, height >= minimumRegionSide else { return [] }
        let tile = Int((Double(sliceLength) * scale).rounded())
        let overlap = Int((Double(Tiling.overlap) * scale).rounded())
        let fits = Int((Double(wholeLength) * scale).rounded())
        let slices = Tiling.spans(length: height, tile: tile, overlap: overlap, fits: fits)
        return zip(slices, Tiling.ownedBands(slices)).map { slice, owned in
            Region(
                rect: PixelRect(x: 0, y: slice.lowerBound, width: width, height: slice.count),
                owned: owned)
        }
    }

    /// Reads every region of `image`, each shown to the recogniser on its `Canvas`, and writes
    /// the text.
    public static func read(
        _ image: CGImage, scale: Double, recognizer: any TextRecognizer
    ) throws -> String {
        var runs: [RecognizedText] = []
        for region in regions(width: image.width, height: image.height, scale: scale) {
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
        return compose(runs) { gutter, rows in
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

    /// Bounds a run can be placed by: finite, and near enough the image that its middle is an
    /// `Int`. A recogniser's NaN or infinite box is dropped rather than trapping the conversion.
    static func usable(_ bounds: CGRect) -> Bool {
        let values = [bounds.minX, bounds.minY, bounds.width, bounds.height]
        return values.allSatisfy { $0.isFinite && abs($0) <= 1e9 }
    }

    /// The text of `runs`: lines in reading order, read as `ReadingOrder.blocks` split by
    /// `backgroundChanges`, which never splits by default. Runs whose bounds aren't `usable` are
    /// dropped. Empty when there is no text.
    public static func compose(
        _ runs: [RecognizedText],
        backgroundChanges: ReadingOrder.BackgroundChange = { _, _ in false }
    ) -> String {
        let blocks = ReadingOrder.blocks(
            runs.filter { usable($0.bounds) }, backgroundChanges: backgroundChanges)
        let lines = ReadingOrder.text(blocks: blocks)
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
