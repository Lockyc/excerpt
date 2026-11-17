import CoreGraphics

/// The sides of a crop a handle moves: one for an edge's handle, two for a corner's.
public struct CropEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = CropEdges(rawValue: 1)
    public static let right = CropEdges(rawValue: 2)
    public static let top = CropEdges(rawValue: 4)
    public static let bottom = CropEdges(rawValue: 8)
}

extension Gestures {
    /// Where a crop edge dragged to `position` lands: on the nearest edge in the picture
    /// (`EdgeSnapper`) along `span`, the crop's extent across it; else on the nearest uniform
    /// line (`GapSnapper`); else where it was dragged. The image's own edges stay put.
    public static func snapCropEdge(
        _ position: Int, axis: Axis, extent: Int, span: Range<Int>, snapping buffer: PixelBuffer?,
        radius: Int
    ) -> Int {
        let clamped = min(max(0, position), extent)
        guard let buffer, clamped > 0, clamped < extent else { return clamped }
        return EdgeSnapper.edge(near: clamped, axis: axis, in: buffer, radius: radius, span: span)
            ?? GapSnapper.snap(clamped, axis: axis, in: buffer, radius: radius)
    }

    /// The sides of `crop` whose edge lies on an edge in the picture, for the canvas to draw a
    /// guide along: what a snap took hold of.
    public static func cropGuides(_ crop: PixelRect, in buffer: PixelBuffer?) -> CropEdges {
        guard let buffer else { return [] }
        let down = crop.y..<(crop.y + crop.height)
        let across = crop.x..<(crop.x + crop.width)
        var guides: CropEdges = []
        if EdgeSnapper.isEdge(at: crop.x, axis: .vertical, in: buffer, span: down) {
            guides.insert(.left)
        }
        if EdgeSnapper.isEdge(at: crop.x + crop.width, axis: .vertical, in: buffer, span: down) {
            guides.insert(.right)
        }
        if EdgeSnapper.isEdge(at: crop.y, axis: .horizontal, in: buffer, span: across) {
            guides.insert(.top)
        }
        if EdgeSnapper.isEdge(at: crop.y + crop.height, axis: .horizontal, in: buffer, span: across)
        {
            guides.insert(.bottom)
        }
        return guides
    }

    /// The handle of `rect` (rendered pixels) within `slop` of `p`: a corner moves two sides,
    /// an edge one. Empty when `p` is near no side, or beside a side but past its ends.
    public static func cropEdges(of rect: CGRect, near p: CGPoint, slop: Double) -> CropEdges {
        let withinX = p.x >= rect.minX - slop && p.x <= rect.maxX + slop
        let withinY = p.y >= rect.minY - slop && p.y <= rect.maxY + slop
        guard withinX, withinY else { return [] }
        var edges: CropEdges = []
        let left = abs(Double(p.x - rect.minX))
        let right = abs(Double(p.x - rect.maxX))
        let top = abs(Double(p.y - rect.minY))
        let bottom = abs(Double(p.y - rect.maxY))
        if min(left, right) <= slop { edges.insert(left <= right ? .left : .right) }
        if min(top, bottom) <= slop { edges.insert(top <= bottom ? .top : .bottom) }
        return edges
    }

    /// `crop` with its `edges` moved to `p` (original pixels), each snapped as a new crop's
    /// edges are, clamped to the image and kept at least `minimum` from the side opposite.
    public static func adjustingCrop(
        _ crop: PixelRect, edges: CropEdges, to p: CGPoint, width: Int, height: Int,
        minimum: Double, snapping buffer: PixelBuffer?, radius: Int
    ) -> PixelRect {
        var left = crop.x
        var right = crop.x + crop.width
        var top = crop.y
        var bottom = crop.y + crop.height
        let least = Int(minimum.rounded(.up))
        let x = Int(p.x.rounded())
        let y = Int(p.y.rounded())
        func snap(_ v: Int, _ axis: Axis, _ extent: Int, _ span: Range<Int>) -> Int {
            snapCropEdge(
                v, axis: axis, extent: extent, span: span, snapping: buffer, radius: radius)
        }
        if edges.contains(.left) {
            left = min(snap(x, .vertical, width, top..<bottom), right - least)
        }
        if edges.contains(.right) {
            right = max(snap(x, .vertical, width, top..<bottom), left + least)
        }
        if edges.contains(.top) {
            top = min(snap(y, .horizontal, height, left..<right), bottom - least)
        }
        if edges.contains(.bottom) {
            bottom = max(snap(y, .horizontal, height, left..<right), top + least)
        }
        left = max(left, 0)
        top = max(top, 0)
        right = min(right, width)
        bottom = min(bottom, height)
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
