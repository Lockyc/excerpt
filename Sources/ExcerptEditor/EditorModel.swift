import CoreGraphics
import CoreText
import ExcerptCore
import ExcerptExport

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
    private(set) var document: EditDocument { didSet { changed() } }
    /// Called after anything the editor shows changed: the document, tool, selection, a drag.
    /// Once per call into the model however much it changed (`batch`), so one input event is
    /// one refresh.
    var onChange: (() -> Void)?
    private var batchDepth = 0
    private var changedInBatch = false
    /// The text being typed: shown live by `displayDocument`, written to the document only by
    /// `endTyping`. Its id is the document annotation it retypes, or the next free id for new
    /// text.
    private(set) var typing: Annotation? { didSet { changed() } }
    private var saved: EditDocument
    private var history = UndoStack<EditDocument>()

    var tool: Tool = .arrow {
        didSet {
            batch {
                endTyping()
                cancelDrag()
                pickingColor = false
                // Pressing the current tool's key again is not a switch: the path carries on.
                if tool != oldValue { finishPath() }
                selection = nil
                changed()
            }
        }
    }
    /// What new annotations get; choosing a colour, size or background sets it.
    private(set) var style: AnnotationStyle {
        didSet { if style != oldValue { onStyleChange?(style) } }
    }
    /// Called when the style changes, so the next editor starts with it.
    var onStyleChange: ((AnnotationStyle) -> Void)?
    /// What the border is, or becomes when turned on: the document's own while it has one,
    /// else the one last chosen — outside the picture either way, so an inside border from an
    /// older document moves out once it is changed.
    private(set) var borderStyle: Border {
        didSet { if borderStyle != oldValue { onBorderStyleChange?(borderStyle) } }
    }
    /// Called when the user picks a border colour or width, so the next editor starts with it.
    var onBorderStyleChange: ((Border) -> Void)?
    var selection: Selection? { didSet { changed() } }
    /// View points per rendered pixel, so hit slop and minimum drags stay the same size on screen.
    var viewScale: Double = 1 {
        didSet { precondition(viewScale > 0, "viewScale must be positive") }
    }
    /// The overlay for a drag in progress.
    private(set) var pending: Pending? { didSet { changed() } }
    /// The drag in progress; undo and redo wait for it to end.
    private(set) var drag: Drag? { didSet { changed() } }
    /// The path being built under the path tool: previewed into the document, recorded once by
    /// `finishPath`.
    private(set) var building: PathBuild? { didSet { changed() } }
    /// The original's pixels, for snapping; read on first use.
    private(set) lazy var pixels = PixelBuffer(original)
    /// The runs of text in the original, in its pixels, that new text matches; nil until read
    /// (`startLoadingTextRuns`), empty when reading failed.
    var textRuns: [RecognizedText]? { readText?.map(\.run) }
    /// Each run read, with the look text started on it takes (`matchedText`), worked out as it
    /// is read, so a click only looks it up.
    private var readText: [(run: RecognizedText, match: MatchedText?)]?
    /// The one read of `textRuns`, once started.
    private var runsLoad: Task<Void, Never>?
    /// Where new text was asked for before `textRuns` were read: begun once they are.
    private var pendingBegin: Pointer? {
        didSet { if pendingBegin != nil || oldValue != nil { changed() } }
    }

    /// A document without a margin colour takes `marginColor` where that leaves its render
    /// unchanged (`EditDocument.adoptMarginColor`), so the picture can grow from here on; that
    /// alone is not an edit.
    init(
        original: CGImage, document: EditDocument, borderStyle: Border = .initial,
        style: AnnotationStyle = .initial, marginColor: RGBA? = nil
    ) {
        var document = document
        if let marginColor {
            document.adoptMarginColor(marginColor, width: original.width, height: original.height)
        }
        self.original = original
        self.style = style
        self.document = document
        self.saved = document
        var borderStyle = document.border ?? borderStyle
        borderStyle.outside = true
        self.borderStyle = borderStyle
    }

    /// Runs `body` as one change: whatever it changes, `onChange` is called once, after it, and
    /// not at all when nothing changed. Nests: only the outermost batch calls it.
    func batch<Result>(_ body: () -> Result) -> Result {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, changedInBatch {
                changedInBatch = false
                onChange?()
            }
        }
        return body()
    }

    /// Marks a change: told now outside a batch, at its end inside one.
    func changed() {
        if batchDepth > 0 { changedInBatch = true } else { onChange?() }
    }

    /// Edits not yet written by ⌘S.
    var isDirty: Bool { document != saved }

    var stepCount: Int { AnnotationGeometry.stepCount(document.annotations) }

    /// Sets the number the first step shows. Not an undo step: a series derives it from the
    /// captures before this one, and re-derives it after an undo restores an older one.
    func setFirstStep(_ first: Int) {
        guard document.firstStep != first else { return }
        document.firstStep = first
    }

    /// Sets whether this capture's steps begin again at 1 in a series, as one undoable step.
    func setRestartsSteps(_ on: Bool) {
        apply { $0.restartsSteps = on }
    }

    /// Takes on the tool and the style for new annotations from another capture in a series,
    /// without telling `onStyleChange`: nothing was chosen.
    func adopt(tool: Tool, style: AnnotationStyle) {
        let tell = onStyleChange
        onStyleChange = nil
        self.style = style
        onStyleChange = tell
        self.tool = tool
    }
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
        batch {
            finishPath()
            if drag != nil { cancelDrag() }
            var next = document
            change(&next)
            guard next != document else { return }
            history.record(document)
            document = next
        }
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
        batch {
            if let building {
                finishPath()
                guard document.annotations.contains(where: { $0.id == building.id }) else {
                    return
                }
            }
            guard drag == nil, let previous = history.undo(from: document) else { return }
            document = previous
            keepSelectionIfPresent()
        }
    }

    /// Does nothing while a drag is in flight or a path is being built.
    func redo() {
        batch {
            guard building == nil, drag == nil, let next = history.redo(from: document) else {
                return
            }
            document = next
            keepSelectionIfPresent()
        }
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

    /// `document` is what ⌘S wrote: the model is clean while its document is that one, so an
    /// edit made while the save was writing stays unsaved.
    func markSaved(_ document: EditDocument) { saved = document }

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

    /// Sets the colour new annotations get, and recolours the selected annotation. A colour
    /// chosen by hand stops a patch following the ground around it.
    func setColor(_ color: AnnotationColor) {
        style.color = color
        restyleSelection { annotation in
            annotation.color = color
            if case .patch(let rect, _) = annotation.shape {
                annotation.shape = .patch(rect: rect, autoColor: false)
            }
        }
    }

    /// Whether the next click on the canvas samples a colour instead of drawing: set by the item
    /// bar's eyedropper, ended by a pick, Escape, or a change of tool.
    private(set) var pickingColor = false { didSet { changed() } }

    func beginPickingColor() { pickingColor = true }

    /// Ends picking, changing nothing.
    func cancelPickingColor() { pickingColor = false }

    /// Takes the colour of the original's pixel under `pointer` (never the render, which has
    /// annotations over it): it becomes the style, the last sample, and the colour of the item
    /// being typed, built or selected. A pointer off the capture picks nothing and picking
    /// carries on.
    func pick(at pointer: Pointer) {
        guard pickingColor, let sampled = ColorSampler.pixel(at: pointer.original, in: pixels)
        else { return }
        batch {
            pickingColor = false
            style.lastSampled = sampled
            setColor(.sampled(sampled))
        }
    }

    /// Sets the size new annotations get, and resizes the selected annotation: text with its
    /// own style takes the preset's text size.
    func setWidth(_ width: StrokeWidth) {
        style.width = width
        restyleSelection { annotation in
            annotation.width = width
            if case .text(let origin, let string, let background, var textStyle?) =
                annotation.shape
            {
                textStyle.points = width.textPoints
                annotation.shape = .text(
                    origin: origin, string: string, background: background, style: textStyle)
            }
        }
    }

    /// Sizes the text being typed or selected, on the size control's grid
    /// (`snappedTextSize`).
    func setTextSize(_ points: Double) {
        restyleText { $0.points = Self.snappedTextSize(points) }
    }

    func setBold(_ on: Bool) { restyleText { $0.bold = on } }

    func setFont(_ font: TextFont) { restyleText { $0.font = font } }

    /// Realigns the text being typed or selected, its lines staying where they start.
    func setAlignment(_ alignment: TextAlign) { restyleText { $0.alignment = alignment } }

    /// Changes the text style of the text being typed or selected; legacy text takes its
    /// implicit style first. A change of alignment moves the origin so the text's left edge
    /// stays put.
    private func restyleText(_ change: (inout TextStyle) -> Void) {
        let scale = document.scale
        restyleSelection { annotation in
            guard case .text(var origin, let string, let background, let current) = annotation.shape
            else { return }
            let before = AnnotationGeometry.textRect(of: annotation, scale: scale)
            var textStyle = current ?? .implicit(annotation.width)
            change(&textStyle)
            annotation.shape = .text(
                origin: origin, string: string, background: background, style: textStyle)
            guard textStyle.alignment != (current?.alignment ?? .left), let before,
                let after = AnnotationGeometry.textRect(of: annotation, scale: scale)
            else { return }
            origin.x += before.minX - after.minX
            annotation.shape = .text(
                origin: origin, string: string, background: background, style: textStyle)
        }
    }

    /// Sets whether new text gets a background, and sets it on the selected text.
    func setBackground(_ on: Bool) {
        style.background = on
        restyleSelection { annotation in
            if case .text(let origin, let string, _, let textStyle) = annotation.shape {
                annotation.shape = .text(
                    origin: origin, string: string, background: on, style: textStyle)
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
        batch {
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

    /// Starts typing into the text under `pointer`, or new text there: matched to the run of
    /// recognised text under it (`TextMatcher`), else in the current style. Whatever was being
    /// typed commits first. While the runs are still being read, new text waits for them
    /// (`isTypingPending`) and begins when they are.
    func beginTyping(at pointer: Pointer, map: RenderMap) {
        batch {
            endTyping()
            if let id = textID(at: pointer, map: map),
                let annotation = document.annotations.first(where: { $0.id == id })
            {
                selection = .annotation(id)
                typing = annotation
                return
            }
            selection = nil
            if isLoadingTextRuns {
                pendingBegin = pointer
            } else {
                typing = newText(at: pointer)
            }
        }
    }

    /// New text was asked for and waits on the text runs being read.
    var isTypingPending: Bool { pendingBegin != nil }

    /// Whether `textRuns` are being read.
    var isLoadingTextRuns: Bool { runsLoad != nil && readText == nil }

    /// Empty text at `pointer`, matched to the run under it when there is one.
    private func newText(at pointer: Pointer) -> Annotation {
        let id = document.nextAnnotationID
        if let matched = readText?.first(where: { $0.run.bounds.contains(pointer.original) })?
            .match
        {
            return Annotation(
                id: id,
                shape: .text(
                    origin: matched.origin, string: "", background: false, style: matched.style),
                color: matched.color, width: style.width)
        }
        return Annotation(
            id: id,
            shape: .text(origin: pointer.original, string: "", background: style.background),
            color: style.color, width: style.width)
    }

    /// Reads the original's runs of text into `textRuns`, and matches each, off the main
    /// thread, once per model: a second call hands back the first's task. A recogniser that
    /// throws leaves them empty. New text asked for meanwhile begins when they are read.
    @MainActor @discardableResult
    func startLoadingTextRuns(using recognizer: any TextRecognizer) -> Task<Void, Never> {
        if let runsLoad { return runsLoad }
        let original = original
        let scale = document.scale
        let load = Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                () -> [(run: RecognizedText, match: MatchedText?)] in
                let runs = (try? CaptureText.runs(of: original, using: recognizer, scale: scale))
                guard let runs, !runs.isEmpty else { return [] }
                let buffer = PixelBuffer(original)
                return runs.map { run in
                    (
                        run,
                        TextMatcher.match(run, in: buffer, scale: scale).map {
                            Self.matchedText($0, scale: scale)
                        }
                    )
                }
            }.value
            self?.finishLoading(read)
        }
        runsLoad = load
        return load
    }

    /// `startLoadingTextRuns`, awaited to its end.
    @MainActor
    func loadTextRuns(using recognizer: any TextRecognizer) async {
        await startLoadingTextRuns(using: recognizer).value
    }

    /// `matched` with its size on the size control's half-point grid (`textSizeStep`), within
    /// `TextStyle.pointsRange`, and its origin moved so the baseline stays on the original's.
    static func matchedText(_ matched: MatchedText, scale: Double) -> MatchedText {
        var style = matched.style
        style.points = snappedTextSize(style.points)
        func ascent(_ style: TextStyle) -> Double {
            Double(
                CTFontGetAscent(
                    TextLayout.font(
                        pixelSize: style.points * scale, font: style.font, bold: style.bold)))
        }
        var origin = matched.origin
        origin.y += ascent(matched.style) - ascent(style)
        return MatchedText(
            origin: origin, style: style, color: matched.color, ground: matched.ground)
    }

    /// The step of the text size control, in points.
    static let textSizeStep = 0.5

    /// `points` on the `textSizeStep` grid, within `TextStyle.pointsRange`.
    static func snappedTextSize(_ points: Double) -> Double {
        let range = TextStyle.pointsRange
        let snapped = (points / textSizeStep).rounded() * textSizeStep
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func finishLoading(_ read: [(run: RecognizedText, match: MatchedText?)]) {
        batch {
            readText = read
            guard let pointer = pendingBegin else { return }
            pendingBegin = nil
            typing = newText(at: pointer)
        }
    }

    var typedString: String { typing.map(Self.string(of:)) ?? "" }

    func updateTyping(_ string: String) {
        guard var typed = typing, case .text(let origin, _, let background, let style) = typed.shape
        else { return }
        typed.shape = .text(origin: origin, string: string, background: background, style: style)
        typing = typed
    }

    /// Ends typing as one undoable step: new text is added, retyped text replaced, and text
    /// emptied removed. The text stays selected. New text still waiting on the text runs is
    /// dropped.
    func endTyping() {
        pendingBegin = nil
        guard let typed = typing else { return }
        batch {
            typing = nil
            let empty = Self.string(of: typed).trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            apply { doc in
                if let i = doc.annotations.firstIndex(where: { $0.id == typed.id }) {
                    if empty { doc.annotations.remove(at: i) } else { doc.annotations[i] = typed }
                } else if !empty {
                    doc.annotations.append(typed)
                }
            }
            selection = empty ? nil : .annotation(typed.id)
        }
    }

    /// Drops the text being typed, removing it from the document if it was already there.
    func deleteTyping() {
        guard let typed = typing else { return }
        batch {
            typing = nil
            apply { $0.annotations.removeAll { $0.id == typed.id } }
            selection = nil
        }
    }

    private static func string(of annotation: Annotation) -> String {
        guard case .text(_, let string, _, _) = annotation.shape else { return "" }
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
        batch {
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
                if tool == .crop {
                    apply { $0.setCrop(nil, width: original.width, height: original.height) }
                }
            }
            selection = nil
        }
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

extension TextStyle {
    /// The style legacy text of `width` (its `style` nil) is drawn in.
    static func implicit(_ width: StrokeWidth) -> TextStyle { TextStyle(points: width.textPoints) }
}
