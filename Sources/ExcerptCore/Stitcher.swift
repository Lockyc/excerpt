/// What adding one frame did to the stitch.
public enum StitchStep: Equatable, Sendable {
    /// `rows` new rows of content joined the stitch.
    case appended(rows: Int)
    case noMovement
    /// The frame didn't match; the stitch is unchanged.
    case uncertain
    /// The stitch is at its maximum height. Rows up to the limit were kept.
    case reachedLimit
}

/// A vertical scrolling capture, built frame by frame. The stitch starts as the first frame, so
/// a sticky header comes from the first frame; each moved frame swaps the previous frame's
/// footer for the new content above its own, so a sticky footer comes from the last frame.
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

    public mutating func add(_ frame: PixelBuffer) -> StitchStep {
        guard !full else { return .reachedLimit }
        switch StitchMatcher.match(reference, frame, ignoringRightColumns: ignoredRightColumns) {
        case .still: return .noMovement
        case .uncertain: return .uncertain
        case .moved(let offset, _, let footer):
            let rowBytes = width * 4
            // The sticky rows on the stitch's tail: the last move's footer, or for the first
            // move the footer it just revealed on the first frame.
            let tail = tailFooter ?? footer
            // The tail covered content that scrolled into view if it shrank or vanished, and
            // the new frame's rows run from where the stitch's content ends to its footer.
            let firstNew = frameHeight - tail - offset
            let count = tail + offset - footer
            // Rows the tail footer hid that the frame doesn't reach: a gap, never a silent hole.
            guard firstNew >= 0 else { return .uncertain }
            // The page moved but a grown footer covers every new row: movement with nothing to
            // add, so a session counting `.noMovement` as the end of the page doesn't stop.
            guard count > 0 else { return .appended(rows: 0) }
            let base = height - tail
            if base + count + footer > maximumHeight {
                // Out of room: keep the stitch contiguous, with no footer after cut-off content.
                bytes.removeLast(tail * rowBytes)
                let rows = min(max(0, maximumHeight - base), count)
                bytes.append(
                    contentsOf: frame.bytes[(firstNew * rowBytes)..<((firstNew + rows) * rowBytes)])
                height = base + rows
                tailFooter = 0
                full = true
                return .reachedLimit
            }
            bytes.removeLast(tail * rowBytes)
            bytes.append(
                contentsOf: frame.bytes[(firstNew * rowBytes)..<((firstNew + count) * rowBytes)])
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
