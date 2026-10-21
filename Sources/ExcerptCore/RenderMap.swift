import CoreGraphics

/// A seam as the editor sees it: the band it removes, in original pixels, and the gap it
/// occupies in the render.
public struct Seam: Equatable, Sendable {
    public let axis: Axis
    public let band: Range<Int>
    public let gap: Range<Int>
}

/// Rendered pixels added around the image on each side, to hold annotations past its edge.
public struct Margin: Equatable, Sendable {
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int

    public init(top: Int = 0, left: Int = 0, bottom: Int = 0, right: Int = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = Margin()
    public var isZero: Bool { self == .zero }
}

/// The one original → rendered placement for a whole render: the crop's offset, then each
/// axis' cuts, then the margin's leading sides. Annotations, hit testing and seam handles all
/// go through it.
public struct RenderMap: Equatable, Sendable {
    /// The region of the original the render shows: the whole image when there is no crop.
    public let crop: PixelRect
    /// Over the crop's height.
    public let rows: AxisMap
    /// Over the crop's width.
    public let columns: AxisMap
    /// Around the image; zero for the base, which annotations haven't grown.
    public let margin: Margin

    public init(crop: PixelRect, rows: AxisMap, columns: AxisMap, margin: Margin = .zero) {
        self.crop = crop
        self.rows = rows
        self.columns = columns
        self.margin = margin
    }

    public func withMargin(_ margin: Margin) -> RenderMap {
        RenderMap(crop: crop, rows: rows, columns: columns, margin: margin)
    }

    public var renderedWidth: Int { margin.left + columns.renderedLength + margin.right }
    public var renderedHeight: Int { margin.top + rows.renderedLength + margin.bottom }

    public func point(_ p: CGPoint, bias: AxisMap.Bias = .middle) -> CGPoint {
        CGPoint(
            x: columns.place(Double(p.x) - Double(crop.x), bias: bias) + Double(margin.left),
            y: rows.place(Double(p.y) - Double(crop.y), bias: bias) + Double(margin.top))
    }

    /// The rendered rect of `r`: leading edges inside a removed band start after its gap,
    /// trailing edges end before it. nil when `r` is hidden by a cut, or when a span with extent
    /// collapses to none (a shape wholly off the image beside an edge band), which a stroke
    /// would otherwise draw as a hairline on the seam.
    public func rect(_ r: CGRect) -> CGRect? {
        guard !isHidden(r) else { return nil }
        let x0 = columns.place(Double(r.minX) - Double(crop.x), bias: .after)
        let x1 = columns.place(Double(r.maxX) - Double(crop.x), bias: .before)
        let y0 = rows.place(Double(r.minY) - Double(crop.y), bias: .after)
        let y1 = rows.place(Double(r.maxY) - Double(crop.y), bias: .before)
        if (r.width > 0 && x1 <= x0) || (r.height > 0 && y1 <= y0) { return nil }
        return CGRect(
            x: x0 + Double(margin.left), y: y0 + Double(margin.top), width: max(0, x1 - x0),
            height: max(0, y1 - y0))
    }

    /// Whether `r` (original pixels) lies wholly inside a removed band on either axis.
    public func isHidden(_ r: CGRect) -> Bool {
        let x = Double(crop.x)
        let y = Double(crop.y)
        return columns.isRemoved(Double(r.minX) - x, Double(r.maxX) - x)
            || rows.isRemoved(Double(r.minY) - y, Double(r.maxY) - y)
    }

    /// The original point shown at rendered point `p`.
    public func original(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: columns.unmap(Double(p.x) - Double(margin.left)) + Double(crop.x),
            y: rows.unmap(Double(p.y) - Double(margin.top)) + Double(crop.y))
    }

    public func seams(_ axis: Axis) -> [Seam] {
        let map = axis == .horizontal ? rows : columns
        let offset = axis == .horizontal ? crop.y : crop.x
        let leading = axis == .horizontal ? margin.top : margin.left
        return zip(map.bands, map.gaps).map { band, gap in
            Seam(
                axis: axis, band: (band.lowerBound + offset)..<(band.upperBound + offset),
                gap: (gap.destination.lowerBound + leading)..<(gap.destination.upperBound + leading)
            )
        }
    }
}
