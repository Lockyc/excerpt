/// The capture coordinator's run, save and quit state, and every decision made from it: what a
/// hotkey does, when a capture is under way, which stopped recordings are still saving, and when
/// a quit may answer. The coordinator holds one and does the AppKit work each answer names.
///
/// `Action` is a hotkey's mode, `Recording` the recording in progress, and `Waiter` a quit
/// waiting to answer; the coordinator's are `HotKeyAction`, `RecordingSession` and a
/// continuation.
public struct CaptureLifecycle<Action: Equatable, Recording, Waiter> {
    /// What a hotkey press does.
    public enum Dispatch {
        /// The Record hotkey again: stop this recording, keeping it.
        case stopRecording(Recording)
        /// Another mode's hotkey while a selection is up: interrupt the selection, which then
        /// runs `switchedTo` on the same stills.
        case switchMode
        /// Pressed mid-capture with nothing to switch: nothing happens.
        case ignore
        /// No capture is under way: run this one. `captureEnded` ends it.
        case start
    }

    /// A pending save, from `recordingEnded(kept: true)` to its `saveEnded`.
    public typealias SaveID = Int

    private let record: Action
    private let selector: Action
    /// Whether a capture is under way, selecting or delivering. A stopped recording's save is
    /// not part of its capture, so the hotkeys work while it renders.
    public private(set) var running = false
    /// The recording in progress.
    public private(set) var recording: Recording?
    /// Stopped recordings still being rendered, saved and delivered.
    public private(set) var saves: Set<SaveID> = []
    private var nextSave: SaveID = 0
    /// The mode whose selection is up.
    public private(set) var selecting: Action?
    /// The mode a hotkey pressed mid-selection, or the mode bar, switched to.
    public var switchedTo: Action?
    /// Quits waiting for the recording and the saves to end.
    private var waiting: [Waiter] = []

    /// `record` is the mode whose hotkey also stops a recording; `selector` the mode bar, which
    /// a hotkey never switches to mid-selection.
    public init(record: Action, selector: Action) {
        self.record = record
        self.selector = selector
    }

    /// Whether a recording is in progress or a stopped one is still saving.
    public var isRecordingOrSaving: Bool { recording != nil || !saves.isEmpty }

    /// A hotkey for `requested`. The Record hotkey stops a recording in progress; mid-capture,
    /// another mode's hotkey switches a selection that is up to it, and any other press is
    /// ignored; otherwise the capture starts.
    public mutating func hotkey(_ requested: Action) -> Dispatch {
        if requested == record, let recording { return .stopRecording(recording) }
        guard !running else {
            guard let selecting, requested != selecting, requested != selector else {
                return .ignore
            }
            switchedTo = requested
            return .switchMode
        }
        running = true
        return .start
    }

    /// The capture `hotkey` started has ended.
    public mutating func captureEnded() { running = false }

    /// A selection for `action` is up, until `selectionEnded`.
    public mutating func selectionBegan(_ action: Action) { selecting = action }

    public mutating func selectionEnded() { selecting = nil }

    /// `recording` has started.
    public mutating func recordingStarted(_ recording: Recording) { self.recording = recording }

    /// The recording has ended; `kept` when it saved a master that is now rendered and saved
    /// in the returned save, the capture ending without waiting for it. Returns the quits that
    /// may now answer.
    public mutating func recordingEnded(kept: Bool) -> (save: SaveID?, replies: [Waiter]) {
        recording = nil
        var save: SaveID?
        if kept {
            save = nextSave
            saves.insert(nextSave)
            nextSave += 1
        }
        return (save, settled())
    }

    /// The save `id` has ended, saved or not. Returns the quits that may now answer.
    public mutating func saveEnded(_ id: SaveID) -> [Waiter] {
        saves.remove(id)
        return settled()
    }

    /// A quit, answered once the recording in progress is stopped and kept and every save has
    /// ended: `stop` is the recording to stop, and `replies` the quits that may answer now.
    public mutating func quitRequested(_ waiter: Waiter) -> (
        stop: Recording?, replies: [Waiter]
    ) {
        waiting.append(waiter)
        return (recording, settled())
    }

    /// The waiting quits, once no recording is in progress or saving.
    private mutating func settled() -> [Waiter] {
        guard !isRecordingOrSaving else { return [] }
        defer { waiting = [] }
        return waiting
    }
}
