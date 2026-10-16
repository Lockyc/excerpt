import CoreGraphics
import ExcerptCore
import Foundation

/// A pointer position in both spaces the editor uses: rendered pixels (what is on screen) and
/// the original pixels they show.
struct Pointer {
    let rendered: CGPoint
    let original: CGPoint

    /// `rendered` is clamped to the render: AppKit keeps sending drag events past the view's
    /// edge, and a shape moved out there could never be pointed at again.
    init(rendered: CGPoint, map: RenderMap) {
        let clamped = CGPoint(
            x: min(max(rendered.x, 0), Double(map.columns.renderedLength)),
            y: min(max(rendered.y, 0), Double(map.rows.renderedLength)))
        self.rendered = clamped
        self.original = map.original(clamped)
    }
}

/// The overlay a drag in progress shows before it changes the document.
enum Pending: Equatable {
    /// The band a cut drag would remove, shaded until release.
    case cut(Cut)
    /// A blur or crop being dragged out, in original pixels.
    case region(CGRect)
    /// A seam handle being dragged: the edge's new position in original pixels.
    case edge(Seam, SeamEdge, Int)
}

/// What a press takes hold of rather than drawing something new.
enum Grab: Equatable {
    /// An edge of the selected seam, dragged to resize its cut.
    case seamEdge(Seam, SeamEdge)
    /// A vertex of the selected path: dragged to reshape, or with ⌥ deleted.
    case vertex(id: Int, index: Int)
    /// With ⌥, segment `index` of the selected path, where a vertex is inserted and dragged.
    case segment(id: Int, index: Int)
    /// The first vertex of the path being built, closing it.
    case closePath
    case seam(Seam)
    /// An annotation, selected and moved.
    case annotation(Int)
}

/// A drag in progress. Shape and move drags have already previewed into the document; `before`
/// is what to record from, or restore on cancel.
enum Drag {
    case shape(id: Int, start: CGPoint, before: EditDocument)
    case region(start: CGPoint)
    case move(id: Int, last: CGPoint, before: EditDocument)
    case edge(Seam, SeamEdge, start: CGPoint)
    /// A press under the path tool: the path's vertices from index `from` on are `raw`.
    case freehand(id: Int, from: Int, raw: [CGPoint])
    /// A selected path's vertex being dragged, held `offset` from the pointer where it was
    /// grabbed, so a press beside it doesn't jump it to the pointer.
    case vertex(id: Int, index: Int, offset: CGPoint, before: EditDocument)
}

extension EditorModel {
    /// Hit slop and the shortest drag that counts, in rendered pixels: 6 and 4 points on screen.
    var slop: Double { 6 / viewScale }
    var minimumDrag: Double { 4 / viewScale }
    var snapRadius: Int { GapSnapper.radius(scale: document.scale) }

    /// What a press at `p` takes hold of under the current tool, before anything new is drawn,
    /// in the order the press tries them; nil when it would draw, select nothing or add to the
    /// path being built. The pointer shows it too, so a press does what the pointer promised.
    func grab(at p: Pointer, map: RenderMap, option: Bool) -> Grab? {
        if let building {
            let points = pathPoints(building.id)
            return points.count >= 3 && isNear(p, points[0], map: map) ? .closePath : nil
        }
        switch tool {
        case .select, .cut:
            if case .seam(let axis, let band) = selection,
                let seam = map.seams(axis).first(where: { $0.band == band }),
                let edge = edge(of: seam, near: p.rendered)
            {
                return .seamEdge(seam, edge)
            }
            if tool == .select, let handle = pathHandle(at: p, map: map, option: option) {
                return handle
            }
            if let seam = HitTest.seam(at: p.rendered, map: map, slop: slop) {
                return .seam(seam)
            }
            guard tool == .select else { return nil }
            return HitTest.annotation(
                at: p.original, in: document.annotations, scale: document.scale, slop: slop,
                map: map
            ).map(Grab.annotation)
        case .path:
            return pathHandle(at: p, map: map, option: option) ?? ownAnnotation(at: p, map: map)
        case .arrow, .rectangle, .highlight, .step, .blur:
            return ownAnnotation(at: p, map: map)
        case .crop, .text:
            return nil
        }
    }

    /// Under a drawing tool, a press on an annotation that tool draws selects it and starts
    /// moving it, as the select tool would, instead of drawing a new one over it. Other kinds
    /// are drawn over, so an arrow can start inside a highlight.
    private func ownAnnotation(at p: Pointer, map: RenderMap) -> Grab? {
        let own = document.annotations.filter { tool.draws($0.shape) }
        return HitTest.annotation(
            at: p.original, in: own, scale: document.scale, slop: slop, map: map
        ).map(Grab.annotation)
    }

    /// Acts on what `grab` found under `p`.
    private func take(_ grab: Grab, at p: Pointer, option: Bool) {
        switch grab {
        case .seamEdge(let seam, let edge):
            setDrag(.edge(seam, edge, start: p.rendered))
            setPending(
                .edge(seam, edge, edge == .before ? seam.band.lowerBound : seam.band.upperBound))
        case .vertex(let id, let index):
            let points = pathPoints(id)
            if option {
                guard points.count > 2 else { return }
                editSelectedPath { points, closed, _ in
                    points.remove(at: index)
                    if points.count < 3 { closed = false }
                }
            } else {
                let offset = CGPoint(
                    x: points[index].x - p.original.x, y: points[index].y - p.original.y)
                setDrag(.vertex(id: id, index: index, offset: offset, before: document))
            }
        case .segment(let id, let index):
            let before = document
            var inserted = pathPoints(id)
            inserted.insert(p.original, at: index + 1)
            previewPathPoints(id, inserted)
            setDrag(.vertex(id: id, index: index + 1, offset: .zero, before: before))
        case .closePath:
            finishPath(closing: true)
        case .seam(let seam):
            selection = .seam(seam.axis, seam.band)
        case .annotation(let id):
            selection = .annotation(id)
            setDrag(.move(id: id, last: p.original, before: document))
        }
    }

    func mouseDown(_ p: Pointer, map: RenderMap, clickCount: Int = 1, option: Bool = false) {
        cancelDrag()
        if building != nil, clickCount >= 2 {
            finishPath()
            return
        }
        if let grab = grab(at: p, map: map, option: option) {
            take(grab, at: p, option: option)
            return
        }
        switch tool {
        case .select, .cut:
            selection = nil
            if tool == .cut { setDrag(.region(start: p.original)) }
        case .arrow, .rectangle, .highlight:
            let before = document
            let id = document.nextAnnotationID
            var next = document
            next.annotations.append(
                Annotation(
                    id: id, shape: shape(from: p.original, to: p.original), color: style.color,
                    width: style.width))
            preview(next)
            selection = nil
            setDrag(.shape(id: id, start: p.original, before: before))
        case .blur, .crop:
            selection = nil
            setDrag(.region(start: p.original))
        case .step:
            let before = document
            let id = document.nextAnnotationID
            var next = document
            next.annotations.append(
                Annotation(
                    id: id, shape: .step(center: p.original), color: style.color,
                    width: style.width))
            preview(next)
            selection = .annotation(id)
            // Placed on press; a drag before release moves it, and release records one step.
            setDrag(.move(id: id, last: p.original, before: before))
        case .path:
            pathMouseDown(p)
        case .text:
            break
        }
    }

    func mouseDragged(_ p: Pointer, map: RenderMap, snap: Bool) {
        switch drag {
        case .shape(let id, let start, _):
            var next = document
            if let i = next.annotations.firstIndex(where: { $0.id == id }) {
                next.annotations[i].shape = shape(from: start, to: p.original)
                preview(next)
            }
        case .region(let start):
            setPending(regionPending(from: start, to: p.original, snap: snap))
        case .move(let id, let last, let before):
            var next = document
            if let i = next.annotations.firstIndex(where: { $0.id == id }) {
                next.annotations[i].shape = next.annotations[i].shape.offset(
                    dx: Double(p.original.x - last.x), dy: Double(p.original.y - last.y))
                preview(next)
                // A moving blur isn't re-rendered until release; its rect is outlined instead.
                if case .blur(let rect) = next.annotations[i].shape { setPending(.region(rect)) }
            }
            setDrag(.move(id: id, last: p.original, before: before))
        case .edge(let seam, let edge, let start):
            let delta = seam.axis == .horizontal ? p.rendered.y - start.y : p.rendered.x - start.x
            let from = edge == .before ? seam.band.lowerBound : seam.band.upperBound
            setPending(.edge(seam, edge, from + Int(Double(delta).rounded())))
        case .freehand(let id, let from, let raw):
            dragFreehand(id: id, from: from, raw: raw, to: p)
        case .vertex(let id, let index, let offset, _):
            var points = pathPoints(id)
            if points.indices.contains(index) {
                points[index] = CGPoint(
                    x: p.original.x + offset.x, y: p.original.y + offset.y)
                previewPathPoints(id, points)
            }
        case nil:
            break
        }
    }

    func mouseUp(_ p: Pointer, map: RenderMap, snap: Bool) {
        mouseDragged(p, map: map, snap: snap)
        let finished = drag
        let shown = pending
        setDrag(nil)
        setPending(nil)
        switch finished {
        case .shape(let id, _, let before):
            guard let annotation = document.annotations.first(where: { $0.id == id }),
                !isTooSmall(annotation.shape)
            else {
                preview(before)
                return
            }
            commit(from: before)
            selection = .annotation(id)
        case .move(_, _, let before):
            commit(from: before)
        case .freehand(let id, let from, let raw):
            endFreehand(id: id, from: from, raw: raw)
        case .vertex(_, _, _, let before):
            commit(from: before)
        case .region:
            switch (tool, shown) {
            case (.cut, .cut(let cut)?):
                apply { $0.cuts.append(cut) }
            case (.blur, .region(let rect)?):
                let id = document.nextAnnotationID
                apply { doc in
                    doc.annotations.append(
                        Annotation(
                            id: id, shape: .blur(rect: rect),
                            color: style.color, width: style.width))
                }
                selection = .annotation(id)
            case (.crop, .region(let rect)?):
                apply {
                    $0.crop = PixelRect(
                        x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width),
                        height: Int(rect.height))
                }
            default:
                break
            }
        case .edge(let seam, let edge, _):
            guard case .edge(_, _, let position)? = shown,
                position != (edge == .before ? seam.band.lowerBound : seam.band.upperBound)
            else { return }
            let extent = seam.axis == .horizontal ? original.height : original.width
            // Cuts live in original pixels: under a crop the seam shows only the part of its
            // band inside the crop, so adjust the whole band and move its edge by the same amount.
            let whole =
                CutSet.normalized(document.cuts, axis: seam.axis, extent: extent)
                .first(where: {
                    $0.lowerBound <= seam.band.lowerBound && seam.band.upperBound <= $0.upperBound
                })
                ?? seam.band
            let shownEdge = edge == .before ? seam.band.lowerBound : seam.band.upperBound
            let wholeEdge = edge == .before ? whole.lowerBound : whole.upperBound
            let cuts = Gestures.adjusting(
                document.cuts, axis: seam.axis, band: whole, edge: edge,
                to: wholeEdge + position - shownEdge,
                extent: extent, snapping: snap ? pixels : nil, radius: snapRadius)
            // A crop-clipped edge dragged within its off-crop overhang changes nothing visible.
            let crop = map.crop
            let visible =
                seam.axis == .horizontal
                ? crop.y..<(crop.y + crop.height) : crop.x..<(crop.x + crop.width)
            func shownBands(_ cuts: [Cut]) -> [Range<Int>] {
                CutSet.normalized(cuts, axis: seam.axis, extent: extent).compactMap { band in
                    let lower = max(band.lowerBound, visible.lowerBound)
                    let upper = min(band.upperBound, visible.upperBound)
                    return lower < upper ? lower..<upper : nil
                }
            }
            guard shownBands(cuts) != shownBands(document.cuts) else { return }
            let kept = Gestures.removing(document.cuts, axis: seam.axis, band: whole)
            apply { $0.cuts = cuts }
            // The cut `adjusting` added is whichever one the surviving cuts don't have; the
            // selection is the part of its band the crop shows.
            if let moved = cuts.first(where: { !kept.contains($0) }),
                let band = CutSet.normalized(cuts, axis: seam.axis, extent: extent)
                    .first(where: { $0.lowerBound <= moved.lower && moved.upper <= $0.upperBound })
            {
                let lower = max(band.lowerBound, visible.lowerBound)
                let upper = min(band.upperBound, visible.upperBound)
                selection = lower < upper ? .seam(seam.axis, lower..<upper) : nil
            }
        case nil:
            break
        }
    }

    /// Abandons a drag in flight: a previewed shape or move goes back to where it started.
    func cancelDrag() {
        switch drag {
        case .shape(_, _, let before), .move(_, _, let before), .vertex(_, _, _, let before):
            preview(before)
        case .freehand(let id, let from, let raw):
            settleFreehand(id: id, from: from, raw: raw)
        default: break
        }
        setDrag(nil)
        setPending(nil)
    }

    /// The new annotation for a drag: an arrow's head is where the drag started.
    func shape(from start: CGPoint, to end: CGPoint) -> Shape {
        let rect = Gestures.rect(from: start, to: end)
        switch tool {
        case .arrow: return .arrow(tail: end, head: start)
        case .highlight: return .highlight(rect: rect)
        default: return .rectangle(rect: rect)
        }
    }

    func regionPending(from start: CGPoint, to end: CGPoint, snap: Bool) -> Pending? {
        switch tool {
        case .cut:
            return Gestures.cut(
                from: start, to: end, width: original.width, height: original.height,
                minimum: minimumDrag, snapping: snap ? pixels : nil, radius: snapRadius
            ).flatMap { isFull($0.axis) ? nil : .cut($0) }
        case .crop:
            return Gestures.crop(
                from: start, to: end, width: original.width, height: original.height,
                minimum: minimumDrag, snapping: snap ? pixels : nil, radius: snapRadius
            ).map { .region($0.cgRect) }
        default:
            let rect = Gestures.rect(from: start, to: end).integral
            guard Double(rect.width) >= minimumDrag, Double(rect.height) >= minimumDrag else {
                return nil
            }
            return .region(rect)
        }
    }

    func isTooSmall(_ shape: Shape) -> Bool {
        switch shape {
        case .arrow(let tail, let head):
            return Double(hypot(head.x - tail.x, head.y - tail.y)) < minimumDrag
        case .rectangle(let rect), .highlight(let rect), .blur(let rect):
            return Double(max(rect.width, rect.height)) < minimumDrag
        case .text, .step, .path:
            return false
        }
    }

    /// The handle of `seam` within slop of rendered point `p`, if any.
    func edge(of seam: Seam, near p: CGPoint) -> SeamEdge? {
        let v = Double(seam.axis == .horizontal ? p.y : p.x)
        let before = abs(v - Double(seam.gap.lowerBound))
        let after = abs(v - Double(seam.gap.upperBound))
        guard min(before, after) <= slop else { return nil }
        return before <= after ? .before : .after
    }
}
