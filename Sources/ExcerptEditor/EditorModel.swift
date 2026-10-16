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
    /// The text being typed: shown live by `displayDocument`, written to the document only by
    /// `endTyping`. Its id is the document annotation it retypes, or the next free id for new
    /// text.
    private(set) var typing: Annotation? { didSet { onChange?() } }
    private var saved: EditDocument
    private var history = UndoStack<EditDocument>()

    var tool: Tool = .arrow {
        didSet {
            endTyping()
            cancelDrag()
            // Pressing the current tool's key again is not a switch: the path carries on.
            if tool != oldValue { finishPath() }
            selection = nil
            onChange?()
        }
    }
    /// What new annotations get; choosing a colour, size or background sets it.
    private(set) var style: AnnotationStyle {
        didSet { if style != oldValue { onStyleChange?(style) } }
    }
    /// Called when the style changes, so the next editor starts with it.
    var onStyleChange: ((AnnotationStyle) -> Void)?
    /// What the border is, or becomes when turned on: the document's own while it has one,
    /// else the one last chosen.
    private(set) var borderStyle: Border {
        didSet { if borderStyle != oldValue { onBorderStyleChange?(borderStyle) } }
    }
    /// Called when the user picks a border colour or width, so the next editor starts with it.
    var onBorderStyleChange: ((Border) -> Void)?
    var selection: Selection? { didSet { onChange?() } }
    /// View points per rendered pixel, so hit slop and minimum drags stay the same size on screen.
    var viewScale: Double = 1 {
        didSet { precondition(viewScale > 0, "viewScale must be positive") }
    }
    /// The overlay for a drag in progress.
    private(set) var pending: Pending? { didSet { onChange?() } }
    /// The drag in progress; undo and redo wait for it to end.
    private(set) var drag: Drag? { didSet { onChange?() } }
    /// The path being built under the path tool: previewed into the document, recorded once by
    /// `finishPath`.
    private(set) var building: PathBuild? { didSet { onChange?() } }
    /// The original's pixels, for snapping; read on first use.
    private(set) lazy var pixels = PixelBuffer(original)

    init(
        original: CGImage, document: EditDocument, borderStyle: Border = .initial,
        style: AnnotationStyle = .initial
    ) {
        self.original = original
        self.style = style
        self.document = document
        self.saved = document
        self.borderStyle = document.border ?? borderStyle
    }

    /// Edits not yet written by ⌘S.
    var isDirty: Bool { document != saved }
    /// A path being built can be undone: undo finishes it, then removes it.
    var canUndo: Bool { history.canUndo || building != nil }
    /// Not while a path is being built or text typed: finishing either records a step, which
    /// clears what redo had.
    var canRedo: Bool { history.canRedo && building == nil && typing == nil }

    /// What the canvas shows: the whole capture while the crop tool is active, so a crop can
    /// be redrawn; otherwise the document, with the text being typed in place of the text it
    /// retypes, or added, and the path being built run on to the pointer, or shown closed while
    /// the pointer is where a press closes it.
    var displayDocument: EditDocument {
        var shown = document
        if tool == .crop { shown.crop = nil }
        if let typing {
            if let i = shown.annotations.firstIndex(where: { $0.id == typing.id }) {
                shown.annotations[i] = typing
            } else {
                shown.annotations.append(typing)
            }
        }
        if let building, drag == nil, let hover = building.hover,
            let i = shown.annotations.firstIndex(where: { $0.id == building.id }),
            case .path(let points, let closed, let fill) = shown.annotations[i].shape
        {
            shown.annotations[i].shape =
                building.closes
                ? .path(points: points, closed: true, fill: fill)
                : .path(points: points + [hover], closed: closed, fill: fill)
        }
        return shown
    }

    /// The part of `displayDocument` the canvas's cached base depends on: everything except the
    /// annotations drawn over it (blurs stay, they change the base's pixels). When this is
    /// unchanged, a repaint redraws only annotations. A blur being moved stays where the drag
    /// began, so the base renders once, on release.
    var baseDocument: EditDocument {
        var base = displayDocument
        if case .move(let id, _, let before)? = drag,
            let start = before.annotations.first(where: { $0.id == id }), start.shape.isBlur,
            let i = base.annotations.firstIndex(where: { $0.id == id })
        {
            base.annotations[i] = start
        }
        base.annotations = base.annotations.filter(\.shape.isBlur)
        return base
    }

    /// One undoable step. A change that leaves the document as it was records nothing. A drag in
    /// flight is cancelled first, so its release can't undo or double-record this change, and a
    /// path being built finishes first.
    func apply(_ change: (inout EditDocument) -> Void) {
        finishPath()
        if drag != nil { cancelDrag() }
        var next = document
        change(&next)
        guard next != document else { return }
        history.record(document)
        document = next
    }

    func setDrag(_ drag: Drag?) { self.drag = drag }
    func setPending(_ pending: Pending?) { self.pending = pending }
    func setBuilding(_ building: PathBuild?) { self.building = building }

    /// Replaces the document without recording a step; a drag's live preview goes through here
    /// and is recorded once, on release, by `commit(from:)`.
    func preview(_ document: EditDocument) { self.document = document }

    /// Records the step from `before` to the current document, if there is one.
    func commit(from before: EditDocument) {
        guard before != document else { return }
        history.record(before)
    }

    /// Does nothing while a drag is in flight, so history can't interleave with a preview. A path
    /// being built finishes first, so undo removes it whole; one too short to keep is dropped,
    /// and that is the whole undo.
    func undo() {
        if let building {
            finishPath()
            guard document.annotations.contains(where: { $0.id == building.id }) else { return }
        }
        guard drag == nil, let previous = history.undo(from: document) else { return }
        document = previous
        keepSelectionIfPresent()
    }

    /// Does nothing while a drag is in flight or a path is being built.
    func redo() {
        guard building == nil, drag == nil, let next = history.redo(from: document) else { return }
        document = next
        keepSelectionIfPresent()
    }

    /// After a history step the selection stays when its annotation or seam is still there.
    private func keepSelectionIfPresent() {
        switch selection {
        case .annotation(let id)?:
            if !document.annotations.contains(where: { $0.id == id }) { selection = nil }
        case .seam(let axis, let band)?:
            let map = Renderer.map(
                width: original.width, height: original.height, edits: displayDocument)
            if !map.seams(axis).contains(where: { $0.band == band }) { selection = nil }
        case nil:
            break
        }
    }

    /// The document now matches what ⌘S wrote.
    func markSaved() { saved = document }

    /// Turns the render's border on or off, as one undoable step.
    func setBorder(_ on: Bool) { apply { $0.border = on ? borderStyle : nil } }

    /// Recolours the border, turning it on: choosing a border colour means wanting one.
    func setBorderColor(_ color: Palette) {
        borderStyle.color = color
        setBorder(true)
    }

    /// Resizes the border, turning it on.
    func setBorderWidth(_ width: Border.Width) {
        borderStyle.width = width
        setBorder(true)
    }

    /// Sets the colour new annotations get, and recolours the selected annotation.
    func setColor(_ color: Palette) {
        style.color = color
        restyleSelection { $0.color = color }
    }

    /// Sets the size new annotations get, and resizes the selected annotation.
    func setWidth(_ width: StrokeWidth) {
        style.width = width
        restyleSelection { $0.width = width }
    }

    /// Sets whether new text gets a background, and sets it on the selected text.
    func setBackground(_ on: Bool) {
        style.background = on
        restyleSelection { annotation in
            if case .text(let origin, let string, _) = annotation.shape {
                annotation.shape = .text(origin: origin, string: string, background: on)
            }
        }
    }

    /// Closes or opens the selected path, as one undoable step; a path of two points stays open.
    func setClosed(_ on: Bool) {
        editSelectedPath { points, closed, _ in closed = on && points.count >= 3 }
    }

    /// Turns the selected path's fill on or off, as one undoable step.
    func setFill(_ on: Bool) { editSelectedPath { _, _, fill in fill = on } }

    /// Changes the selected path's points, closed flag or fill, as one undoable step; does
    /// nothing unless a path is selected. A path being built finishes first, selected, so the
    /// bar's Closed acts on it.
    func editSelectedPath(_ change: (inout [CGPoint], inout Bool, inout Bool) -> Void) {
        finishPath()
        guard case .annotation(let id) = selection else { return }
        apply { doc in
            guard let i = doc.annotations.firstIndex(where: { $0.id == id }),
                case .path(var points, var closed, var fill) = doc.annotations[i].shape
            else { return }
            change(&points, &closed, &fill)
            doc.annotations[i].shape = .path(points: points, closed: closed, fill: fill)
        }
    }

    /// Whether colour and size apply to the selection: an annotation other than a blur, which
    /// has neither.
    var selectionTakesStyle: Bool {
        guard case .annotation(let id) = selection,
            let annotation = document.annotations.first(where: { $0.id == id })
        else { return false }
        return !annotation.shape.isBlur
    }

    /// Restyles the text being typed or the path being built, else the selected annotation (one
    /// undoable step).
    private func restyleSelection(_ change: (inout Annotation) -> Void) {
        if var typed = typing {
            change(&typed)
            typing = typed
            return
        }
        // The path being built restyles in its preview, recorded with it when it finishes.
        if let building,
            let i = document.annotations.firstIndex(where: { $0.id == building.id })
        {
            var next = document
            change(&next.annotations[i])
            preview(next)
            return
        }
        guard case .annotation(let id) = selection, selectionTakesStyle else { return }
        apply { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) {
                change(&doc.annotations[i])
            }
        }
    }

    /// The text annotation under `pointer`, if any.
    func textID(at pointer: Pointer, map: RenderMap) -> Int? {
        guard
            let id = HitTest.annotation(
                at: pointer.rendered, in: document.annotations, scale: document.scale, slop: 0,
                map: map),
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .text = annotation.shape
        else { return nil }
        return id
    }

    /// Starts typing into the text under `pointer`, or new text there in the current style.
    /// Whatever was being typed commits first.
    func beginTyping(at pointer: Pointer, map: RenderMap) {
        endTyping()
        if let id = textID(at: pointer, map: map),
            let annotation = document.annotations.first(where: { $0.id == id })
        {
            selection = .annotation(id)
            typing = annotation
            return
        }
        selection = nil
        typing = Annotation(
            id: document.nextAnnotationID,
            shape: .text(origin: pointer.original, string: "", background: style.background),
            color: style.color, width: style.width)
    }

    var typedString: String { typing.map(Self.string(of:)) ?? "" }

    func updateTyping(_ string: String) {
        guard var typed = typing, case .text(let origin, _, let background) = typed.shape else {
            return
        }
        typed.shape = .text(origin: origin, string: string, background: background)
        typing = typed
    }

    /// Ends typing as one undoable step: new text is added, retyped text replaced, and text
    /// emptied removed. The text stays selected. Does nothing when nothing is being typed.
    func endTyping() {
        guard let typed = typing else { return }
        typing = nil
        let empty = Self.string(of: typed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        apply { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == typed.id }) {
                if empty { doc.annotations.remove(at: i) } else { doc.annotations[i] = typed }
            } else if !empty {
                doc.annotations.append(typed)
            }
        }
        selection = empty ? nil : .annotation(typed.id)
    }

    /// Drops the text being typed, removing it from the document if it was already there.
    func deleteTyping() {
        guard let typed = typing else { return }
        typing = nil
        apply { $0.annotations.removeAll { $0.id == typed.id } }
        selection = nil
    }

    private static func string(of annotation: Annotation) -> String {
        guard case .text(_, let string, _) = annotation.shape else { return "" }
        return string
    }

    /// Whether `deleteSelection` would remove something: the selection, or under the crop tool
    /// with nothing selected, the crop.
    var canDelete: Bool {
        building != nil || selection != nil || (tool == .crop && document.crop != nil)
    }

    /// Removes the selected annotation or seam; with nothing selected under the crop tool,
    /// removes the crop. A path being built is abandoned, recording nothing.
    func deleteSelection() {
        if let building {
            setBuilding(nil)
            if case .freehand? = drag { setDrag(nil) }
            preview(building.before)
            return
        }
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

    /// The selected step's index in the document and the indices of the steps either side of it
    /// in step order; nil unless a step is selected.
    private var selectedStep: (index: Int, earlier: Int?, later: Int?)? {
        guard case .annotation(let id) = selection,
            let index = document.annotations.firstIndex(where: { $0.id == id }),
            document.annotations[index].shape.isStep
        else { return nil }
        let steps = document.annotations.indices.filter { document.annotations[$0].shape.isStep }
        let rank = steps.firstIndex(of: index)!
        return (
            index, rank > 0 ? steps[rank - 1] : nil, rank + 1 < steps.count ? steps[rank + 1] : nil
        )
    }

    var canMoveStepEarlier: Bool { selectedStep?.earlier != nil }
    var canMoveStepLater: Bool { selectedStep?.later != nil }

    /// Swaps the selected step with the one numbered before or after it, as one undoable step.
    func moveStep(earlier: Bool) {
        guard let step = selectedStep, let other = earlier ? step.earlier : step.later else {
            return
        }
        apply { $0.annotations.swapAt(step.index, other) }
    }

    /// Whether `axis` already has `EditDocument.maximumCutsPerAxis` cuts: another would save a
    /// master that reads as damaged, so the cut tool makes none there.
    func isFull(_ axis: Axis) -> Bool {
        document.cuts.lazy.filter { $0.axis == axis }.count >= EditDocument.maximumCutsPerAxis
    }

    /// The line the cut tool shows for an axis that takes no more cuts; empty when both do.
    var cutLimitNote: String {
        let limit = EditDocument.maximumCutsPerAxis.formatted()
        let full = [(Axis.horizontal, "row"), (.vertical, "column")].filter { isFull($0.0) }
        guard !full.isEmpty else { return "" }
        let axes = full.map(\.1).joined(separator: " and ")
        return "\(limit) \(axes) cuts, the most a capture holds"
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
