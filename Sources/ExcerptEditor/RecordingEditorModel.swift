import CoreGraphics
import ExcerptCore
import ExcerptRecording

/// What the recording editor holds: the recording's edit document, the playhead and the selected
/// blur. Every change to the document is one undo step; the playhead and selection are not
/// undone.
public struct RecordingEditorModel {
    /// The shortest trim: a clip of a single frame or less isn't a recording.
    public static let minimumTrim = 0.1

    /// Seconds.
    public let duration: Double
    /// The master's frame in pixels; blur rects are kept inside it.
    public let pixelSize: CGSize
    public let log: RecordingEventLog
    public private(set) var edits: RecordingEdits
    /// Seconds into the master, always inside the trim.
    public var playhead: Double {
        didSet { playhead = clampedToTrim(playhead) }
    }
    /// The index of the selected blur.
    public private(set) var selection: Int?
    private var saved: RecordingEdits
    private var history = UndoStack<RecordingEdits>()
    /// Whether a continuing change joins the last undo step.
    private var stepOpen = false
    private var frames = Frames.reading

    /// Where the master's frame stamps stand: a span is set from them.
    private enum Frames {
        case reading
        case read([Double])
        case unreadable
    }

    /// The master's edits, or a fresh document in `defaultFormat` for a master without any.
    public init(master: RecordingMaster, defaultFormat: RecordingFormat = .gif) {
        self.init(
            duration: master.duration, pixelSize: master.pixelSize, log: master.log,
            edits: master.edits, defaultFormat: defaultFormat)
    }

    init(
        duration: Double, pixelSize: CGSize, log: RecordingEventLog, edits: RecordingEdits?,
        defaultFormat: RecordingFormat
    ) {
        self.duration = duration
        self.pixelSize = pixelSize
        self.log = log
        let edits = edits ?? .fresh(duration: duration, format: defaultFormat)
        self.edits = edits
        saved = edits
        playhead = edits.trim.lowerBound
    }

    public var hasUnsavedChanges: Bool { edits != saved }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    /// Why the Shortcuts toggle can't be turned on; nil when it can.
    public var shortcutsUnavailableReason: String? {
        log.shortcutsLogged ? nil : "Input Monitoring was off for this recording"
    }

    /// Keeps `range` inside the clip and at least `minimumTrim` long. When it is too short the
    /// end being dragged gives way: the start when only the start moved, else the end. With
    /// `continuing`, the change joins the previous one's undo step, as each step of a drag does.
    public mutating func setTrim(_ range: ClosedRange<Double>, continuing: Bool = false) {
        let minimum = min(Self.minimumTrim, duration)
        var lower = min(max(range.lowerBound, 0), duration)
        var upper = min(max(range.upperBound, 0), duration)
        if upper - lower < minimum {
            if lower != edits.trim.lowerBound && upper == edits.trim.upperBound {
                lower = upper - minimum
            } else {
                upper = lower + minimum
            }
            if upper > duration { (lower, upper) = (duration - minimum, duration) }
            if lower < 0 { (lower, upper) = (0, minimum) }
        }
        change(continuing: continuing) { $0.trim = lower...upper }
    }

    /// Adds a whole-clip blur over `rect` (master pixels, top-left origin) cut to the frame,
    /// and selects it; a rect wholly outside the frame adds nothing.
    public mutating func addBlur(_ rect: CGRect) {
        let frame = CGRect(origin: .zero, size: pixelSize)
        let kept = rect.standardized.intersection(frame)
        guard !kept.isNull, kept.width >= 1, kept.height >= 1,
            edits.blurs.count < EditDocument.maximumAnnotations
        else { return }
        change { $0.blurs.append(RecordingBlur(rect: kept)) }
        selection = edits.blurs.count - 1
    }

    /// Puts blur `index` back over the whole clip.
    public mutating func setWholeClip(ofBlur index: Int) { setSpan(nil, ofBlur: index) }

    /// Limits blur `index` to `span`, kept inside the clip; nil covers the whole clip.
    private mutating func setSpan(_ span: ClosedRange<Double>?, ofBlur index: Int) {
        guard edits.blurs.indices.contains(index) else { return }
        let kept = span.map { span in
            min(max(span.lowerBound, 0), duration)...min(max(span.upperBound, 0), duration)
        }
        change { $0.blurs[index].span = kept }
    }

    /// The master's frame stamps, once read; nil, after `setFrameTimes(nil)`, when they
    /// couldn't be.
    public mutating func setFrameTimes(_ times: [Double]?) {
        frames = times.map { .read($0.sorted()) } ?? .unreadable
    }

    /// Why a span can't be set at the playhead yet; nil when it can.
    var spanUnavailableReason: String? {
        switch frames {
        case .reading: "Reading the recording's frames…"
        case .unreadable: "The recording's frames couldn't be read"
        case .read(let times): times.isEmpty ? "The recording has no frames" : nil
        }
    }

    /// The index of the frame the exporter renders at the playhead: the last stamped at or
    /// before it within `RecordingExporter.frameTolerance`, else the first. Nil until the frame
    /// stamps are read.
    var shownFrameIndex: Int? {
        guard case .read(let times) = frames, !times.isEmpty else { return nil }
        return times.lastIndex { $0 <= playhead + RecordingExporter.frameTolerance } ?? 0
    }

    /// The time the preview decodes its frame at, so it shows exactly `shownFrameIndex`'s
    /// frame: midway to the next stamp (to the clip's end after the last), well clear of both
    /// edges, so neither the decoder's time rounding nor the tolerance can land it on a
    /// neighbour. Until the stamps are read, the playhead, kept short of the clip's end, where
    /// no frame decodes.
    var previewFrameTime: Double {
        guard case .read(let times) = frames, let k = shownFrameIndex else {
            return min(playhead, max(duration - 1.0 / 600, 0))
        }
        let next = k + 1 < times.count ? times[k + 1] : max(duration, times[k])
        return (times[k] + next) / 2
    }

    /// Every time at which the exporter renders the frame shown at the playhead: from that
    /// frame's stamp to the next one's, both less `RecordingExporter.frameTolerance` and
    /// widened a hair either way so rounding never lets an export sample of the frame fall
    /// outside, never empty. Nil until the frame stamps are read. A span set at the playhead
    /// covers all of it, so no sample of the frame it was set on renders unblurred.
    var shownFrame: ClosedRange<Double>? {
        guard case .read(let times) = frames, let k = shownFrameIndex else { return nil }
        let tolerance = RecordingExporter.frameTolerance
        let start = k == 0 ? 0 : max(0, times[k] - tolerance - 1e-6)
        let next = k + 1 < times.count ? min(duration, times[k + 1] - tolerance + 1e-6) : duration
        let end = max(next, min(duration, start + 1 / Double(MasterWriter.frameRate)))
        return start...max(end, start)
    }

    /// Starts blur `index` with the frame at the playhead, keeping its end when that is still
    /// after the playhead, else running it to the clip's end, so a wider trim later still hides
    /// what it hides; it always covers that frame.
    public mutating func startSpan(ofBlur index: Int) {
        guard edits.blurs.indices.contains(index), let frame = shownFrame else { return }
        let kept = edits.blurs[index].span?.upperBound
        let end = kept.flatMap { $0 > playhead ? $0 : nil } ?? duration
        setSpan(frame.lowerBound...max(end, frame.upperBound), ofBlur: index)
    }

    /// Ends blur `index` with the frame at the playhead, keeping its start when that is still
    /// before the playhead, else starting it with the clip, so a wider trim later still hides
    /// what it hides; it always covers that frame.
    public mutating func endSpan(ofBlur index: Int) {
        guard edits.blurs.indices.contains(index), let frame = shownFrame else { return }
        let kept = edits.blurs[index].span?.lowerBound
        let start = kept.flatMap { $0 < playhead ? $0 : nil } ?? 0
        setSpan(min(start, frame.lowerBound)...frame.upperBound, ofBlur: index)
    }

    public mutating func removeBlur(_ index: Int) {
        guard edits.blurs.indices.contains(index) else { return }
        change { $0.blurs.remove(at: index) }
        selection = nil
    }

    /// Selects blur `index`; nil, or an index out of range, selects nothing.
    public mutating func select(_ index: Int?) {
        selection = index.flatMap { edits.blurs.indices.contains($0) ? $0 : nil }
    }

    public mutating func setShowsShortcuts(_ on: Bool) { change { $0.showsShortcuts = on } }
    public mutating func setShowsClicks(_ on: Bool) { change { $0.showsClicks = on } }
    public mutating func setFormat(_ format: RecordingFormat) { change { $0.format = format } }

    public mutating func undo() {
        guard let previous = history.undo(from: edits) else { return }
        restore(previous)
    }

    public mutating func redo() {
        guard let next = history.redo(from: edits) else { return }
        restore(next)
    }

    /// The edits as they now are have been written to the master.
    public mutating func markSaved() { saved = edits }

    /// The selected blur's item bar: its span set from the playhead, back to the whole clip,
    /// and delete.
    var itemOptions: [ItemOption]? {
        guard let selection else { return nil }
        let reason = spanUnavailableReason
        return [
            .spanStart(unavailable: reason), .spanEnd(unavailable: reason),
            .wholeClip(enabled: edits.blurs[selection].span != nil), .delete,
        ]
    }

    /// Applies `edit` as its own undo step, or with `continuing` as part of the step the last
    /// change without it began (a step of its own when that one changed nothing). An edit that
    /// changes nothing isn't a step.
    private mutating func change(continuing: Bool = false, _ edit: (inout RecordingEdits) -> Void) {
        var changed = edits
        edit(&changed)
        guard changed != edits else {
            if !continuing { stepOpen = false }
            return
        }
        if !continuing || !stepOpen { history.record(edits) }
        stepOpen = true
        edits = changed
        playhead = clampedToTrim(playhead)
    }

    private mutating func restore(_ value: RecordingEdits) {
        edits = value
        stepOpen = false
        if let selection, !edits.blurs.indices.contains(selection) { self.selection = nil }
        playhead = clampedToTrim(playhead)
    }

    private func clampedToTrim(_ t: Double) -> Double {
        min(max(t, edits.trim.lowerBound), edits.trim.upperBound)
    }
}
