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
            let rows = min(offset, maximumHeight - height)
            guard rows > 0 else {
                full = true
                return .reachedLimit
            }
            let rowBytes = width * 4
            let firstNew = frameHeight - footer - offset
            bytes.removeLast(footer * rowBytes)
            bytes.append(
                contentsOf: frame.bytes[(firstNew * rowBytes)..<((firstNew + rows) * rowBytes)])
            bytes.append(contentsOf: frame.bytes[((frameHeight - footer) * rowBytes)...])
            height += rows
            reference = frame
            if rows < offset {
                full = true
                return .reachedLimit
            }
            return .appended(rows: rows)
        }
    }

    /// The whole stitch.
    public var image: PixelBuffer { PixelBuffer(width: width, height: height, bytes: bytes) }

    /// The bottom `rows` of the stitch (all of it when shorter): the live preview's view.
    public func bottom(rows: Int) -> PixelBuffer {
        let count = min(max(1, rows), height)
        let rowBytes = width * 4
        return PixelBuffer(
            width: width, height: count, bytes: Array(bytes[((height - count) * rowBytes)...]))
    }
}
