import CoreGraphics
import ExcerptCore
import Foundation

/// A path being built: its annotation, the document before it began, and where the pointer
/// hovers, which the path's last segment runs on to until the next click.
struct PathBuild: Equatable {
    let id: Int
    let before: EditDocument
    var hover: CGPoint?
    /// The pointer is on the first vertex, where a press closes the path.
    var closes = false
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

    /// A press under the path tool that `grab` left to it: while building, a vertex added there,
    /// which may drag out a freehand run; otherwise a new path started there.
    func pathMouseDown(_ p: Pointer) {
        guard canAddPathPoints(1) else { return }
        if let building {
            let points = pathPoints(building.id)
            previewPathPoints(building.id, points + [p.original])
            setDrag(.freehand(id: building.id, from: points.count, raw: [p.original]))
            return
        }
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

    /// Ends a press under the path tool: settles its run, and a drag that began the path
    /// finishes it.
    func endFreehand(id: Int, from: Int, raw: [CGPoint]) {
        if settleFreehand(id: id, from: from, raw: raw), from == 0 { finishPath() }
    }

    /// Turns a press's run into vertices; true when it was a drag. A press that never strayed
    /// `minimumDrag` from where it began is a click, however it jittered: its one vertex stays.
    /// A drag is simplified, so a run cut short by a tool switch or a lost release is too.
    @discardableResult
    func settleFreehand(id: Int, from: Int, raw: [CGPoint]) -> Bool {
        let reach = raw.map { Double(hypot($0.x - raw[0].x, $0.y - raw[0].y)) }.max() ?? 0
        let kept = Array(pathPoints(id).prefix(from))
        guard reach >= minimumDrag else {
            previewPathPoints(id, kept + [raw[0]])
            return false
        }
        let width =
            document.annotations.first(where: { $0.id == id })
            .map { AnnotationGeometry.lineWidth($0, scale: document.scale) } ?? 1
        previewPathPoints(id, kept + Gestures.simplify(raw, tolerance: width / 2))
        return true
    }

    /// Ends the path being built as one undoable step, selected; `closing` closes one of three
    /// or more vertices. A path left with under two vertices is dropped and records nothing.
    func finishPath(closing: Bool = false) {
        guard let building else { return }
        if case .freehand(let id, let from, let raw)? = drag {
            setDrag(nil)
            settleFreehand(id: id, from: from, raw: raw)
        }
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

    /// The selected path's own handle under `p`: a vertex (dragged to reshape, or with ⌥
    /// deleted, never below two; a closed path under three opens), or with ⌥ a segment, where a
    /// vertex is inserted and dragged. Nil off the selected path's handles.
    func pathHandle(at p: Pointer, map: RenderMap, option: Bool) -> Grab? {
        guard case .annotation(let id) = selection,
            let note = document.annotations.first(where: { $0.id == id }),
            case .path(let points, let closed, _) = note.shape
        else { return nil }
        if let index = points.indices.first(where: { isNear(p, points[$0], map: map) }) {
            return .vertex(id: id, index: index)
        }
        guard option, canAddPathPoints(1) else { return nil }
        let reach = AnnotationGeometry.lineWidth(note, scale: document.scale) / 2 + slop
        let segments = AnnotationGeometry.segments(points, closed: closed)
        return segments.indices.first(where: {
            HitTest.distance(from: p.original, toSegment: segments[$0].0, segments[$0].1) <= reach
        }).map { .segment(id: id, index: $0) }
    }

    /// Where the pointer is, for the path being built's last segment; nil when it leaves. On
    /// the first vertex, where a press would close the path, the path shows closed.
    func hover(_ p: Pointer?, map: RenderMap) {
        guard var building else { return }
        building.hover = p?.original
        building.closes = p.map { grab(at: $0, map: map, option: false) == .closePath } ?? false
        setBuilding(building)
    }
}
