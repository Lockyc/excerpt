/// What adding one frame did to the stitch.
public enum StitchStep: Equatable, Sendable {
    /// `rows` new rows of content joined the stitch. 0 means the page moved but a grown footer
    /// covers every new row: a session treats any `.appended` as movement.
    case appended(rows: Int)
    case noMovement
    /// The frame didn't match; the stitch is unchanged.
    case uncertain
    /// The page moved `offset` rows, outside the travel the caller expected; the stitch is
    /// unchanged.
    case unexpectedTravel(offset: Int)
    /// The stitch is at its maximum height. Rows up to the limit were kept.
    case reachedLimit
}

/// A vertical scrolling capture, built frame by frame. The stitch starts as the first frame, so
/// a sticky header comes from the first frame; each moved frame swaps the previous frame's
/// footer for the new content above its own, so a sticky footer comes from the last frame.
/// Columns outside each move's scrolling band take their commonest colour (`content`).
public struct Stitcher: Sendable {
    /// The tallest stitch, in image pixels.
    public static let defaultMaximumHeight = 30_000

    public let width: Int
    public let frameHeight: Int
    public let maximumHeight: Int
    public let ignoredRightColumns: Int
    public private(set) var height: Int
    private var bytes: [UInt8]
    /// The last frame joined to the stitch: every frame is matched against it.
    private var reference: PixelBuffer
    private var full = false
    /// Rows at the stitch's end that are the newest frame's sticky footer; nil until the first
    /// move shows how many of the first frame's bottom rows are sticky.
    private var tailFooter: Int?

    /// `maximumHeight` below the first frame's height is raised to it: the first frame is kept
    /// whole.
    public init(first: PixelBuffer, scale: Double, maximumHeight: Int = defaultMaximumHeight) {
        width = first.width
        frameHeight = first.height
        self.maximumHeight = max(maximumHeight, first.height)
        ignoredRightColumns = StitchMatcher.ignoredRightColumns(width: first.width, scale: scale)
        height = first.height
        bytes = first.bytes
        reference = first
    }

    /// Joins `frame` to the stitch. With `travel`, a move by an offset outside it is not
    /// joined: the caller knows how far the page should have moved, and repeated content can
    /// alias a jump of more than a frame as a small move.
    public mutating func add(_ frame: PixelBuffer, travel: ClosedRange<Int>? = nil) -> StitchStep {
        guard !full else { return .reachedLimit }
        switch StitchMatcher.match(reference, frame, ignoringRightColumns: ignoredRightColumns) {
        case .still: return .noMovement
        case .uncertain: return .uncertain
        case .moved(let offset, let header, let footer, let band):
            if let travel, !travel.contains(offset) { return .unexpectedTravel(offset: offset) }
            let rowBytes = width * 4
            // The sticky rows on the stitch's tail: the last move's footer, or for the first
            // move the footer it just revealed on the first frame.
            let tail = tailFooter ?? footer
            // The tail covered content that scrolled into view if it shrank or vanished, and
            // the new frame's rows run from where the stitch's content ends to its footer.
            let firstNew = frameHeight - tail - offset
            let count = tail + offset - footer
            // The match must rest on content the stitch holds: an overlap inside the old tail
            // footer and the header (a footer that unsticks into the page's flow) would paste
            // the frame's header rows mid-stitch, and a frame that starts past the stitch's end
            // leaves a gap.
            guard firstNew - header >= StitchMatcher.minimumEvidenceRows else { return .uncertain }
            // The page moved but a grown footer covers every new row: movement with nothing to
            // add, so a session counting `.noMovement` as the end of the page doesn't stop.
            guard count > 0 else { return .appended(rows: 0) }
            // The new frame's rows the previous frame also shows, `offset` rows lower.
            let overlap = header..<(frameHeight - footer - offset)
            let base = height - tail
            if base + count + footer > maximumHeight {
                // Out of room: keep the stitch contiguous, with no footer after cut-off content.
                bytes.removeLast(tail * rowBytes)
                let rows = min(max(0, maximumHeight - base), count)
                bytes.append(
                    contentsOf: Self.content(
                        frame, rows: firstNew..<(firstNew + rows), band: band,
                        matched: width - ignoredRightColumns, previous: reference, offset: offset,
                        overlap: overlap))
                height = base + rows
                tailFooter = 0
                full = true
                return .reachedLimit
            }
            bytes.removeLast(tail * rowBytes)
            bytes.append(
                contentsOf: Self.content(
                    frame, rows: firstNew..<(firstNew + count), band: band,
                    matched: width - ignoredRightColumns, previous: reference, offset: offset,
                    overlap: overlap))
            bytes.append(contentsOf: frame.bytes[((frameHeight - footer) * rowBytes)...])
            height = base + count + footer
            tailFooter = footer
            reference = frame
            if height == maximumHeight {
                full = true
                return .reachedLimit
            }
            return .appended(rows: count)
        }
    }

    /// The whole stitch. Copies the buffer: a live view calls `bottom(rows:)` instead, never
    /// `image` after every `add`.
    public var image: PixelBuffer { PixelBuffer(width: width, height: height, bytes: bytes) }

    /// The bottom `rows` of the stitch (all of it when shorter, at least one row): the live
    /// preview's view.
    public func bottom(rows: Int) -> PixelBuffer {
        let count = min(max(1, rows), height)
        let rowBytes = width * 4
        return PixelBuffer(
            width: width, height: count, bytes: Array(bytes[((height - count) * rowBytes)...]))
    }
}

extension Stitcher {
    /// Rows of `frame` for the stitch. The scrolling band, the scroll-bar strip (columns from
    /// `matched` on) and every column that moved by `offset` too (each of its `overlap` rows
    /// is `previous`'s row `offset` lower: page columns the coarse band left out, margins,
    /// borders that repeat with the scroll) are copied. The rest didn't scroll with the page,
    /// so each takes its commonest colour in the frame: a side panel shows once, where the
    /// first frame has it, and the page's background runs on under it.
    static func content(
        _ frame: PixelBuffer, rows: Range<Int>, band: Range<Int>, matched: Int,
        previous: PixelBuffer, offset: Int, overlap: Range<Int>
    ) -> [UInt8] {
        let rowBytes = frame.width * 4
        var out = Array(frame.bytes[(rows.lowerBound * rowBytes)..<(rows.upperBound * rowBytes)])
        let side = (Array(0..<min(band.lowerBound, matched)) + Array(band.upperBound..<matched))
            .filter { x in
                !overlap.allSatisfy { previous[x: x, y: $0 + offset] == frame[x: x, y: $0] }
            }
        guard !side.isEmpty, !rows.isEmpty else { return out }
        let fill = commonestColours(frame, columns: side)
        out.withUnsafeMutableBytes { raw in
            for r in 0..<rows.count {
                for (i, x) in side.enumerated() {
                    raw.storeBytes(
                        of: fill[i], toByteOffset: (r * frame.width + x) * 4, as: UInt32.self)
                }
            }
        }
        return out
    }

    /// Each column's commonest pixel over every fourth row; on a tie the smaller value, so the
    /// same frame always fills the same.
    static func commonestColours(_ frame: PixelBuffer, columns: [Int]) -> [UInt32] {
        frame.bytes.withUnsafeBytes { raw in
            columns.map { x in
                var counts: [UInt32: Int] = [:]
                for y in stride(from: 0, to: frame.height, by: 4) {
                    let pixel = raw.loadUnaligned(
                        fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self)
                    counts[pixel, default: 0] += 1
                }
                return counts.max {
                    $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
                }!.key
            }
        }
    }
}
