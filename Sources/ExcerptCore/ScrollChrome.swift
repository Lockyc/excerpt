/// What a scrolling capture of a window knows about the window's own chrome, as against the page
/// scrolling inside it: rows its shape fixes in place, and whether its scroll-bar strip is filled.
/// An area capture has none (`none`).
public struct ScrollChrome: Equatable, Sendable {
    /// Rows at the top that are header at least, whatever the frames share there.
    public var fixedTop: Int
    /// Rows at the bottom that are footer at least, whatever the frames share there.
    public var fixedBottom: Int
    /// The right-edge scroll-bar strip (`StitchMatcher.ignoredRightColumns`) takes each column's
    /// commonest colour in appended rows, as a side panel does: a window's scroll bar is its own,
    /// so its thumb shows once, from the first frame. An area's strip is copied, since page
    /// content may reach the area's edge.
    public var fillsScrollBar: Bool

    public init(fixedTop: Int, fixedBottom: Int, fillsScrollBar: Bool) {
        self.fixedTop = fixedTop
        self.fixedBottom = fixedBottom
        self.fillsScrollBar = fillsScrollBar
    }

    public static let none = ScrollChrome(fixedTop: 0, fixedBottom: 0, fillsScrollBar: false)

    /// From a window frame's alpha: the rows from the top and from the bottom whose first or last
    /// fully opaque pixel lies further in than the middle row's, its rounded corners. The middle
    /// row's inset is the window's edge, so a translucent border down every row is not shape. A
    /// row with no fully opaque pixel is shape.
    public static func window(shapeOf frame: PixelBuffer) -> ScrollChrome {
        let insets = (0..<frame.height).map { inset(ofRow: $0, in: frame) }
        let edge = insets.isEmpty ? 0 : insets[frame.height / 2]
        let top = insets.prefix { $0 > edge }.count
        let bottom = insets.reversed().prefix { $0 > edge }.count
        return ScrollChrome(fixedTop: top, fixedBottom: bottom, fillsScrollBar: true)
    }

    /// The fewer of the columns before row `y`'s first fully opaque pixel and after its last;
    /// the frame's width when the row has none.
    static func inset(ofRow y: Int, in frame: PixelBuffer) -> Int {
        frame.bytes.withUnsafeBytes { raw in
            func opaque(_ x: Int) -> Bool {
                raw[(y * frame.width + x) * 4 + 3] == 255
            }
            guard let left = (0..<frame.width).first(where: opaque) else { return frame.width }
            let right = (0..<frame.width).reversed().first(where: opaque)!
            return min(left, frame.width - 1 - right)
        }
    }
}
