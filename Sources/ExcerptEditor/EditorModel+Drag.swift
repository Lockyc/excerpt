import CoreGraphics
import ExcerptCore
import Foundation

/// A pointer position in both spaces the editor uses: rendered pixels (what is on screen) and
/// the original pixels they show.
struct Pointer {
    let rendered: CGPoint
    let original: CGPoint

    init(rendered: CGPoint, map: RenderMap) {
        self.rendered = rendered
        self.original = map.original(rendered)
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

/// Text being typed: a new annotation when `id` is nil.
struct TextTarget: Equatable {
    let id: Int?
    let origin: CGPoint
    let string: String
    let color: Palette
    let width: StrokeWidth
}

/// A drag in progress. Shape and move drags have already previewed into the document; `before`
/// is what to record from, or restore on cancel.
enum Drag {
    case shape(id: Int, start: CGPoint, before: EditDocument)
    case region(start: CGPoint)
    case move(id: Int, last: CGPoint, before: EditDocument)
    case edge(Seam, SeamEdge, start: CGPoint)
}

extension EditorModel {
    /// Hit slop and the shortest drag that counts, in rendered pixels: 6 and 4 points on screen.
    var slop: Double { 6 / viewScale }
    var minimumDrag: Double { 4 / viewScale }
    var snapRadius: Int { GapSnapper.radius(scale: document.scale) }

    func mouseDown(_ p: Pointer, map: RenderMap) {
        cancelDrag()
        switch tool {
        case .select, .cut:
            if case .seam(let axis, let band) = selection,
                let seam = map.seams(axis).first(where: { $0.band == band }),
                let edge = edge(of: seam, near: p.rendered)
            {
                setDrag(.edge(seam, edge, start: p.rendered))
                setPending(.edge(seam, edge, edge == .before ? band.lowerBound : band.upperBound))
                return
            }
            if let seam = HitTest.seam(at: p.rendered, map: map, slop: slop) {
                selection = .seam(seam.axis, seam.band)
                return
            }
            if tool == .select,
                let id = HitTest.annotation(
                    at: p.original, in: document.annotations, scale: document.scale, slop: slop,
                    map: map)
            {
                selection = .annotation(id)
                setDrag(.move(id: id, last: p.original, before: document))
                return
            }
            selection = nil
            if tool == .cut { setDrag(.region(start: p.original)) }
        case .arrow, .rectangle, .highlight:
            let before = document
            let id = document.nextAnnotationID
            var next = document
            next.annotations.append(
                Annotation(
                    id: id, shape: shape(from: p.original, to: p.original), color: color,
                    width: width))
            preview(next)
            selection = nil
            setDrag(.shape(id: id, start: p.original, before: before))
        case .blur, .crop:
            selection = nil
            setDrag(.region(start: p.original))
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
        case .region:
            switch (tool, shown) {
            case (.cut, .cut(let cut)?):
                apply { $0.cuts.append(cut) }
            case (.blur, .region(let rect)?):
                apply { doc in
                    doc.annotations.append(
                        Annotation(
                            id: doc.nextAnnotationID, shape: .blur(rect: rect), color: color,
                            width: width))
                }
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
        case .shape(_, _, let before), .move(_, _, let before): preview(before)
        default: break
        }
        setDrag(nil)
        setPending(nil)
    }

    /// What typing at `pointer` edits: the text annotation under it, or new text.
    func textTarget(at pointer: Pointer, map: RenderMap) -> TextTarget {
        let p = pointer.original
        if let id = HitTest.annotation(
            at: p, in: document.annotations, scale: document.scale, slop: 0, map: map),
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .text(let origin, let string) = annotation.shape
        {
            selection = .annotation(id)
            return TextTarget(
                id: id, origin: origin, string: string, color: annotation.color,
                width: annotation.width)
        }
        return TextTarget(id: nil, origin: p, string: "", color: color, width: width)
    }

    /// Ends typing: new text is added, edited text replaced, and text emptied removed.
    func commitText(_ target: TextTarget, string: String) {
        let empty = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        apply { doc in
            if let id = target.id {
                if empty {
                    doc.annotations.removeAll { $0.id == id }
                } else if let i = doc.annotations.firstIndex(where: { $0.id == id }) {
                    doc.annotations[i].shape = .text(origin: target.origin, string: string)
                }
            } else if !empty {
                doc.annotations.append(
                    Annotation(
                        id: doc.nextAnnotationID,
                        shape: .text(origin: target.origin, string: string), color: target.color,
                        width: target.width))
            }
        }
        if empty { selection = nil }
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
        case .text:
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
