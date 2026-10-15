import CoreGraphics
import ExcerptCore
import Foundation

/// A path being built: its annotation, the document before it began, and where the pointer
/// hovers, which the path's last segment runs on to until the next click.
struct PathBuild: Equatable {
    let id: Int
    let before: EditDocument
    var hover: CGPoint?
}

extension EditorModel {
    /// How near a vertex a press must be to take it, in rendered pixels: 8 points on screen.
    var handleReach: Double { 8 / viewScale }

    /// Whether rendered point `p` is within `handleReach` of original vertex `vertex`.
    func isNear(_ p: Pointer, _ vertex: CGPoint, map: RenderMap) -> Bool {
        let placed = map.point(vertex)
        return Double(hypot(p.rendered.x - placed.x, p.rendered.y - placed.y)) <= handleReach
    }

    func pathPoints(_ id: Int) -> [CGPoint] {
        guard let note = document.annotations.first(where: { $0.id == id }),
            case .path(let points, _, _) = note.shape
        else { return [] }
        return points
    }

    /// Replaces path `id`'s points in a preview, unrecorded.
    func previewPathPoints(_ id: Int, _ points: [CGPoint]) {
        var next = document
        guard let i = next.annotations.firstIndex(where: { $0.id == id }),
            case .path(_, let closed, let fill) = next.annotations[i].shape
        else { return }
        next.annotations[i].shape = .path(points: points, closed: closed, fill: fill)
        preview(next)
    }

    /// Whether the document can take `count` more path vertices and still save.
    func canAddPathPoints(_ count: Int) -> Bool {
        document.pathPointCount + count <= EditDocument.maximumPathPoints
    }

    /// A press under the path tool. Building: a double-click finishes, a press on the first of
    /// three or more vertices closes, any other press adds a vertex and may drag out a freehand
    /// run. Not building: a press on the selected path's handles edits it, one on a path grabs
    /// it, else a new path starts there.
    func pathMouseDown(_ p: Pointer, map: RenderMap, clickCount: Int, option: Bool) {
        if let building {
            if clickCount >= 2 {
                finishPath()
                return
            }
            let points = pathPoints(building.id)
            if points.count >= 3, isNear(p, points[0], map: map) {
                finishPath(closing: true)
                return
            }
            guard canAddPathPoints(1) else { return }
            previewPathPoints(building.id, points + [p.original])
            setDrag(.freehand(id: building.id, from: points.count, raw: [p.original]))
            return
        }
        if editVertex(at: p, map: map, option: option) { return }
        if grabAnnotation(at: p, map: map) { return }
        guard canAddPathPoints(1) else { return }
        let before = document
        let id = document.nextAnnotationID
        var next = document
        next.annotations.append(
            Annotation(
                id: id, shape: .path(points: [p.original], closed: false, fill: false),
                color: style.color, width: style.width))
        preview(next)
        selection = nil
        setBuilding(PathBuild(id: id, before: before, hover: nil))
        setDrag(.freehand(id: id, from: 0, raw: [p.original]))
    }

    /// A freehand run in flight: the path is its points before the run, then the run.
    func dragFreehand(id: Int, from: Int, raw: [CGPoint], to p: Pointer) {
        var raw = raw
        if canAddPathPoints(1) { raw.append(p.original) }
        setDrag(.freehand(id: id, from: from, raw: raw))
        previewPathPoints(id, Array(pathPoints(id).prefix(from)) + raw)
    }

    /// Ends a press under the path tool. A press that barely moved is a click: its vertex
    /// stays. A real drag is simplified to vertices, and when it began the path, finishes it.
    func endFreehand(id: Int, from: Int, raw: [CGPoint]) {
        let travelled = zip(raw, raw.dropFirst()).reduce(0.0) {
            $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y))
        }
        let kept = Array(pathPoints(id).prefix(from))
        guard travelled >= minimumDrag else {
            previewPathPoints(id, kept + [raw[0]])
            return
        }
        let width =
            document.annotations.first(where: { $0.id == id })
            .map { AnnotationGeometry.lineWidth($0, scale: document.scale) } ?? 1
        previewPathPoints(id, kept + Gestures.simplify(raw, tolerance: width / 2))
        if from == 0 { finishPath() }
    }

    /// Ends the path being built as one undoable step, selected; `closing` closes one of three
    /// or more vertices. A path left with under two vertices is dropped and records nothing.
    func finishPath(closing: Bool = false) {
        guard let building else { return }
        if case .freehand? = drag { setDrag(nil) }
        setBuilding(nil)
        var points: [CGPoint] = []
        for p in pathPoints(building.id) {
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.5 { continue }
            points.append(p)
        }
        guard points.count >= 2 else {
            preview(building.before)
            return
        }
        var next = document
        if let i = next.annotations.firstIndex(where: { $0.id == building.id }),
            case .path(_, _, let fill) = next.annotations[i].shape
        {
            next.annotations[i].shape = .path(
                points: points, closed: closing && points.count >= 3, fill: fill)
        }
        preview(next)
        commit(from: building.before)
        selection = .annotation(building.id)
    }

    /// Escape while building: drops the last vertex; dropping the only one abandons the path.
    func dropLastVertex() {
        guard let building else { return }
        let points = pathPoints(building.id)
        guard points.count > 1 else {
            setBuilding(nil)
            preview(building.before)
            return
        }
        previewPathPoints(building.id, Array(points.dropLast()))
    }

    /// A press on the selected path's own handles: a vertex is dragged to reshape, or with ⌥
    /// deleted (never below two; a closed path under three opens); with ⌥ on a segment a vertex
    /// is inserted there and dragged. False when the press isn't on the selected path's handles
    /// or, with ⌥, its segments.
    func editVertex(at p: Pointer, map: RenderMap, option: Bool) -> Bool {
        guard building == nil, case .annotation(let id) = selection,
            let note = document.annotations.first(where: { $0.id == id }),
            case .path(let points, let closed, _) = note.shape
        else { return false }
        if let index = points.indices.first(where: { isNear(p, points[$0], map: map) }) {
            if option {
                guard points.count > 2 else { return true }
                editSelectedPath { points, closed, _ in
                    points.remove(at: index)
                    if points.count < 3 { closed = false }
                }
            } else {
                setDrag(.vertex(id: id, index: index, before: document))
            }
            return true
        }
        guard option, canAddPathPoints(1) else { return false }
        let reach = AnnotationGeometry.lineWidth(note, scale: document.scale) / 2 + slop
        let segments = AnnotationGeometry.segments(points, closed: closed)
        guard
            let segment = segments.indices.first(where: {
                HitTest.distance(from: p.original, toSegment: segments[$0].0, segments[$0].1)
                    <= reach
            })
        else { return false }
        let before = document
        var inserted = points
        inserted.insert(p.original, at: segment + 1)
        previewPathPoints(id, inserted)
        setDrag(.vertex(id: id, index: segment + 1, before: before))
        return true
    }

    /// Where the pointer is, for the path being built's last segment; nil when it leaves.
    func hover(_ p: Pointer?) {
        guard var building else { return }
        building.hover = p?.original
        setBuilding(building)
    }
}
