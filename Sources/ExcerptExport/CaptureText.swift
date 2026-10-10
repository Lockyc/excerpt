import CoreGraphics
import ExcerptCore
import Foundation

/// Reads the text in an image and returns its runs, bounds in the image's pixels, top-left
/// origin. The one seam between excerpt and an OCR engine, so everything around it is tested
/// without one.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) throws -> [RecognizedText]
}

public enum CaptureTextError: Error, Equatable, LocalizedError {
    /// The render's cuts split it into more regions than `CaptureText.maximumRegions`.
    case tooManyRegions(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyRegions(let count):
            "Its cuts split it into \(count) parts to read; text is read from at most \(CaptureText.maximumRegions)."
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

    /// Regions too thin to hold a line of text are not read.
    public static let minimumRegionSide = 8

    /// Every region to read, top to bottom, then left to right.
    public static func regions(of map: RenderMap, scale: Double) -> [Region] {
        let tile = Int((Double(Tiling.tileLength) * scale).rounded())
        let overlap = Int((Double(Tiling.overlap) * scale).rounded())
        let fits = Int((Double(Tiling.readerLongEdge) * scale).rounded())
        var regions: [Region] = []
        for rows in map.rows.segments where rows.source.count >= minimumRegionSide {
            let slices = Tiling.spans(
                length: rows.source.count, tile: tile, overlap: overlap, fits: fits)
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

    /// Reads every region of `image`, the render `map` describes, and writes the text. Throws
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
            for run in try recognizer.recognize(piece) {
                let bounds = run.bounds.offsetBy(
                    dx: CGFloat(region.rect.x), dy: CGFloat(region.rect.y))
                if usable(bounds), region.owned.contains(Int(bounds.midY)) {
                    runs.append(RecognizedText(run.string, bounds))
                }
            }
        }
        return compose(runs, map: map, scale: scale)
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
    /// aren't `usable` are dropped. Empty when there is neither text nor a cut.
    public static func compose(_ runs: [RecognizedText], map: RenderMap, scale: Double) -> String {
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
            let lines = ReadingOrder.lines(runs.filter { rows.contains(Int($0.bounds.midY)) })
            body += ReadingOrder.text(lines, write: write)
        }
        body += gaps.map { marker(removedPixels: $0.removed, scale: scale) }
        let unspanned = map.columns.gaps.indices.filter { !spanned.contains($0) }.map {
            marker(removedPixels: map.columns.gaps[$0].removed, scale: scale)
        }
        let all = unspanned + body
        return all.isEmpty ? "" : all.joined(separator: "\n") + "\n"
    }
}
