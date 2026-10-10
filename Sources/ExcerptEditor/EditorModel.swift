import CoreGraphics
import ExcerptCore

/// What is selected: an annotation by id, or a seam by the band it removes (original pixels).
enum Selection: Equatable {
    case annotation(Int)
    case seam(Axis, Range<Int>)
}

/// The editor's state as plain values, with no AppKit: the document, undo, the current tool and
/// style, and the selection. The window and canvas forward input here and draw what it holds.
/// Documents keep the salt they were loaded or created with, so identical edits render
/// identical pixels across undo and redo.
final class EditorModel {
    let original: CGImage
    private(set) var document: EditDocument { didSet { onChange?() } }
    /// Called after anything the editor shows changed: the document, tool, selection, a drag.
    var onChange: (() -> Void)?
    /// The text annotation being retyped in place; the display hides it while the field is up.
    var editingID: Int? { didSet { onChange?() } }
    private var saved: EditDocument
    private var history = UndoStack<EditDocument>()

    var tool: Tool = .select {
        didSet {
            cancelDrag()
            selection = nil
            onChange?()
        }
    }
    private(set) var color: Palette = .initial
    private(set) var width: StrokeWidth = .initial
    var selection: Selection? { didSet { onChange?() } }
    /// View points per rendered pixel, so hit slop and minimum drags stay the same size on screen.
    var viewScale: Double = 1 {
        didSet { precondition(viewScale > 0, "viewScale must be positive") }
    }
    /// The overlay for a drag in progress.
    private(set) var pending: Pending? { didSet { onChange?() } }
    /// The drag in progress; undo and redo wait for it to end.
    private(set) var drag: Drag? { didSet { onChange?() } }
    /// The original's pixels, for snapping; read on first use.
    private(set) lazy var pixels = PixelBuffer(original)

    init(original: CGImage, document: EditDocument) {
        self.original = original
        self.document = document
        self.saved = document
    }

    /// Edits not yet written by ⌘S.
    var isDirty: Bool { document != saved }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// What the canvas shows: the whole capture while the crop tool is active, so a crop can
    /// be redrawn; otherwise the document, less the text being retyped.
    var displayDocument: EditDocument {
        var shown = document
        if tool == .crop { shown.crop = nil }
        if let editingID { shown.annotations.removeAll { $0.id == editingID } }
        return shown
    }

    /// The part of `displayDocument` the canvas's cached base depends on: everything except the
    /// annotations drawn over it (blurs stay, they change the base's pixels). When this is
    /// unchanged, a repaint redraws only annotations.
    var baseDocument: EditDocument {
        var base = displayDocument
        base.annotations = base.annotations.filter(\.shape.isBlur)
        return base
    }

    /// One undoable step. A change that leaves the document as it was records nothing. A drag in
    /// flight is cancelled first, so its release can't undo or double-record this change.
    func apply(_ change: (inout EditDocument) -> Void) {
        if drag != nil { cancelDrag() }
        var next = document
        change(&next)
        guard next != document else { return }
        history.record(document)
        document = next
    }

    func setDrag(_ drag: Drag?) { self.drag = drag }
    func setPending(_ pending: Pending?) { self.pending = pending }

    /// Replaces the document without recording a step; a drag's live preview goes through here
    /// and is recorded once, on release, by `commit(from:)`.
    func preview(_ document: EditDocument) { self.document = document }

    /// Records the step from `before` to the current document, if there is one.
    func commit(from before: EditDocument) {
        guard before != document else { return }
        history.record(before)
    }

    /// Does nothing while a drag is in flight, so history can't interleave with a preview.
    func undo() {
        guard drag == nil, let previous = history.undo(from: document) else { return }
        document = previous
        keepSelectionIfPresent()
    }

    /// Does nothing while a drag is in flight.
    func redo() {
        guard drag == nil, let next = history.redo(from: document) else { return }
        document = next
        keepSelectionIfPresent()
    }

    /// After a history step the selection stays when its annotation or seam is still there.
    private func keepSelectionIfPresent() {
        switch selection {
        case .annotation(let id)?:
            if !document.annotations.contains(where: { $0.id == id }) { selection = nil }
        case .seam(let axis, let band)?:
            let extent = axis == .horizontal ? original.height : original.width
            let bands = CutSet.normalized(document.cuts, axis: axis, extent: extent)
            if !bands.contains(band) { selection = nil }
        case nil:
            break
        }
    }

    /// The document now matches what ⌘S wrote.
    func markSaved() { saved = document }

    /// Sets the colour new annotations get, and recolours the selected annotation.
    func setColor(_ color: Palette) {
        self.color = color
        restyleSelection { $0.color = color }
    }

    /// Sets the width new annotations get, and restyles the selected annotation.
    func setWidth(_ width: StrokeWidth) {
        self.width = width
        restyleSelection { $0.width = width }
    }

    private func restyleSelection(_ change: (inout Annotation) -> Void) {
        guard case .annotation(let id) = selection else { return }
        apply { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) {
                change(&doc.annotations[i])
            }
        }
    }

    /// Whether `deleteSelection` would remove something: the selection, or under the crop tool
    /// with nothing selected, the crop.
    var canDelete: Bool { selection != nil || (tool == .crop && document.crop != nil) }

    /// Removes the selected annotation or seam; with nothing selected under the crop tool,
    /// removes the crop.
    func deleteSelection() {
        switch selection {
        case .annotation(let id):
            apply { $0.annotations.removeAll { $0.id == id } }
        case .seam(let axis, let band):
            apply { $0.cuts = Gestures.removing($0.cuts, axis: axis, band: band) }
        case nil:
            if tool == .crop { apply { $0.crop = nil } }
        }
        selection = nil
    }

    /// The line the editor shows for annotations a cut hides; empty when there are none.
    func hiddenNote(map: RenderMap) -> String {
        let count = AnnotationGeometry.hiddenCount(
            document.annotations, map: map, scale: document.scale)
        switch count {
        case 0: return ""
        case 1: return "1 annotation hidden by a cut"
        default: return "\(count) annotations hidden by cuts"
        }
    }
}
