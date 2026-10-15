import CoreGraphics

/// Which side of a seam a handle moves: `before` is the removed band's first line, `after` is
/// one past its last.
public enum SeamEdge: Sendable {
    case before
    case after
}

/// What a click lands on, in the coordinates the editor has: original pixels for annotations,
/// rendered pixels for seams.
public enum HitTest {
    /// The topmost annotation under `p` (original pixels): within `slop` of an arrow's shaft or a
    /// path's segments (or inside a filled closed path), or of any other annotation's bounds. `slop` is in original pixels (`scale` already converts
    /// stroke points to original pixels). An annotation the render doesn't draw
    /// (`AnnotationGeometry.isDrawn` under `map`) can't be hit.
    public static func annotation(
        at p: CGPoint, in annotations: [Annotation], scale: Double, slop: Double,
        map: RenderMap
    ) -> Int? {
        for annotation in annotations.reversed() {
            if !AnnotationGeometry.isDrawn(annotation, map: map, scale: scale) { continue }
            switch annotation.shape {
            case .arrow(let tail, let head):
                let reach = AnnotationGeometry.lineWidth(annotation, scale: scale) / 2 + slop
                if distance(from: p, toSegment: tail, head) <= reach { return annotation.id }
            case .path(let points, let closed, let fill):
                let reach = AnnotationGeometry.lineWidth(annotation, scale: scale) / 2 + slop
                let onStroke = AnnotationGeometry.segments(points, closed: closed).contains {
                    distance(from: p, toSegment: $0.0, $0.1) <= reach
                }
                if onStroke || (closed && fill && contains(p, polygon: points)) {
                    return annotation.id
                }
            default:
                let bounds = AnnotationGeometry.bounds(of: annotation, scale: scale)
                let reach = bounds.insetBy(dx: -slop, dy: -slop)
                if p.x >= reach.minX, p.x <= reach.maxX, p.y >= reach.minY, p.y <= reach.maxY {
                    return annotation.id
                }
            }
        }
        return nil
    }

    /// The seam whose gap is nearest rendered point `p`, within `slop` rendered pixels (`slop`
    /// is in rendered pixels). Where seams cross, the smaller distance wins, then the seam whose
    /// centre line is nearer `p`, then the vertical one.
    public static func seam(at p: CGPoint, map: RenderMap, slop: Double) -> Seam? {
        func candidate(_ seam: Seam, _ v: CGFloat) -> (Seam, Double, Double) {
            let centre = Double(seam.gap.lowerBound + seam.gap.upperBound) / 2
            return (seam, distance(Double(v), to: seam.gap), abs(Double(v) - centre))
        }
        let candidates =
            map.seams(.vertical).map { candidate($0, p.x) }
            + map.seams(.horizontal).map { candidate($0, p.y) }
        return candidates.filter { $0.1 <= slop }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    static func distance(_ v: Double, to range: Range<Int>) -> Double {
        if v < Double(range.lowerBound) { return Double(range.lowerBound) - v }
        if v > Double(range.upperBound) { return v - Double(range.upperBound) }
        return 0
    }

    /// Whether `p` is inside `polygon` by the even-odd rule.
    public static func contains(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
                Double(p.x) < Double(b.x - a.x) * Double(p.y - a.y) / Double(b.y - a.y)
                    + Double(a.x)
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        let t =
            lengthSquared == 0
            ? 0 : min(1, max(0, (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / lengthSquared))
        let x = Double(a.x) + t * dx - Double(p.x)
        let y = Double(a.y) + t * dy - Double(p.y)
        return (x * x + y * y).squareRoot()
    }
}

/// Turning drags into cuts and crops, in original pixels. Snapping goes through `GapSnapper`
/// over the original pixels; pass `snapping: nil` (⌥ held) to keep the dragged positions.
public enum Gestures {
    /// The rect a rectangle, highlight or blur drag makes: standardised, so a drag up and to the
    /// left never yields the negative size `EditDocument` refuses to decode.
    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
            height: abs(end.y - start.y))
    }

    /// `position` snapped to a uniform line, unless it is on the image boundary (`0` or
    /// `extent`), which has no line of its own to test and stays put. The one snapping rule for
    /// cuts, seam handles and crops.
    static func snapEdge(
        _ position: Int, axis: Axis, extent: Int, snapping buffer: PixelBuffer?, radius: Int
    ) -> Int {
        let clamped = min(max(0, position), extent)
        guard let buffer, clamped > 0, clamped < extent else { return clamped }
        return GapSnapper.snap(clamped, axis: axis, in: buffer, radius: radius)
    }

    /// The cut a drag makes, clamped to the `width` x `height` image. A mostly vertical drag
    /// removes rows (a horizontal cut); a mostly horizontal one removes columns; an exact
    /// diagonal removes rows. nil when the drag is shorter than `minimum` along its axis or the
    /// clamped, snapped cut is empty.
    public static func cut(
        from start: CGPoint, to end: CGPoint, width: Int, height: Int, minimum: Double,
        snapping buffer: PixelBuffer?, radius: Int
    ) -> Cut? {
        let dx = abs(Double(end.x - start.x))
        let dy = abs(Double(end.y - start.y))
        let axis: Axis = dy >= dx ? .horizontal : .vertical
        let extent = axis == .horizontal ? height : width
        let a = Double(axis == .horizontal ? start.y : start.x)
        let b = Double(axis == .horizontal ? end.y : end.x)
        guard abs(b - a) >= minimum, abs(b - a) > 0 else { return nil }
        var lower = Int(min(a, b).rounded())
        var upper = Int(max(a, b).rounded())
        lower = min(max(0, lower), extent)
        upper = min(max(0, upper), extent)
        let snappedLower = snapEdge(
            lower, axis: axis, extent: extent, snapping: buffer, radius: radius)
        let snappedUpper = snapEdge(
            upper, axis: axis, extent: extent, snapping: buffer, radius: radius)
        if snappedLower < snappedUpper {
            lower = snappedLower
            upper = snappedUpper
        }
        guard upper > lower else { return nil }
        return Cut(axis: axis, lower: lower, upper: upper)
    }

    /// `cuts` with the seam removing `band` on `axis` moved so that its `edge` is at `position`:
    /// every cut making up the band is replaced by one cut. The edge stays at least one line
    /// from the other edge and inside `0...extent`.
    public static func adjusting(
        _ cuts: [Cut], axis: Axis, band: Range<Int>, edge: SeamEdge, to position: Int,
        extent: Int, snapping buffer: PixelBuffer?, radius: Int
    ) -> [Cut] {
        let target = snapEdge(
            position, axis: axis, extent: extent, snapping: buffer, radius: radius)
        var lower = band.lowerBound
        var upper = band.upperBound
        switch edge {
        case .before: lower = min(max(0, target), upper - 1)
        case .after: upper = max(min(extent, target), lower + 1)
        }
        return removing(cuts, axis: axis, band: band) + [
            Cut(axis: axis, lower: lower, upper: upper)
        ]
    }

    /// `cuts` without every cut making up the seam that removes `band` on `axis`.
    public static func removing(_ cuts: [Cut], axis: Axis, band: Range<Int>) -> [Cut] {
        cuts.filter { cut in
            cut.axis != axis || cut.upper <= cut.lower || cut.upper < band.lowerBound
                || cut.lower > band.upperBound
        }
    }

    /// `points` without every vertex within `tolerance` of the segment its kept neighbours
    /// draw (Ramer–Douglas–Peucker): a freehand stroke as the fewest straight segments that keep
    /// its shape. The first and last points always stay.
    public static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]
        while let (first, last) = spans.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var greatest = -1.0
            for i in (first + 1)..<last {
                let d = HitTest.distance(from: points[i], toSegment: points[first], points[last])
                if d > greatest {
                    greatest = d
                    farthest = i
                }
            }
            if greatest > tolerance {
                keep[farthest] = true
                spans.append((first, farthest))
                spans.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// The crop a drag makes: the dragged rect clamped to the image, its edges snapped to
    /// uniform lines. nil when either side ends up shorter than `minimum`.
    public static func crop(
        from start: CGPoint, to end: CGPoint, width: Int, height: Int, minimum: Double,
        snapping buffer: PixelBuffer?, radius: Int
    ) -> PixelRect? {
        func clamp(_ v: CGFloat, _ extent: Int) -> Int { min(max(0, Int(v.rounded())), extent) }
        var left = clamp(min(start.x, end.x), width)
        var right = clamp(max(start.x, end.x), width)
        var top = clamp(min(start.y, end.y), height)
        var bottom = clamp(max(start.y, end.y), height)
        let l = snapEdge(left, axis: .vertical, extent: width, snapping: buffer, radius: radius)
        let r = snapEdge(right, axis: .vertical, extent: width, snapping: buffer, radius: radius)
        let t = snapEdge(top, axis: .horizontal, extent: height, snapping: buffer, radius: radius)
        let b = snapEdge(
            bottom, axis: .horizontal, extent: height, snapping: buffer, radius: radius)
        if l < r {
            left = l
            right = r
        }
        if t < b {
            top = t
            bottom = b
        }
        guard Double(right - left) >= minimum, Double(bottom - top) >= minimum else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
