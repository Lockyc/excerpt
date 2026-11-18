import ExcerptTestSupport
import PropertyBased
import Testing

@testable import ExcerptCore

/// The modes a test presses; `record` also stops a recording, and `selector` is the mode bar.
enum Mode: Equatable {
    case area, window, record, selector
}

/// A lifecycle whose recordings and waiting quits are numbered.
typealias Lifecycle = CaptureLifecycle<Mode, Int, Int>

func lifecycle() -> Lifecycle { Lifecycle(record: .record, selector: .selector) }

extension Lifecycle.Dispatch {
    var starts: Bool { if case .start = self { true } else { false } }
    var switches: Bool { if case .switchMode = self { true } else { false } }
    var ignores: Bool { if case .ignore = self { true } else { false } }
    var stops: Int? { if case .stopRecording(let recording) = self { recording } else { nil } }
}

@Suite struct CaptureLifecycleTests {
    /// 811a3c8: the Record hotkey stops a recording, its save starts, and a screenshot hotkey
    /// pressed while that save renders starts a capture.
    @Test func aHotkeyStartsACaptureWhileAStoppedRecordingSaves() {
        var life = lifecycle()
        #expect(life.hotkey(.record).starts)
        life.recordingStarted(1)
        #expect(life.hotkey(.record).stops == 1)
        let ended = life.recordingEnded(kept: true)
        #expect(ended.save != nil)
        life.captureEnded()
        #expect(life.isRecordingOrSaving)
        #expect(life.hotkey(.area).starts)
    }

    /// 8cfccc9: a quit mid-recording stops the recording and answers only once it is kept and
    /// its save has ended.
    @Test func aQuitMidRecordingStopsItAndWaitsForItsSave() {
        var life = lifecycle()
        _ = life.hotkey(.record)
        life.recordingStarted(1)
        let quit = life.quitRequested(7)
        #expect(quit.stop == 1)
        #expect(quit.replies.isEmpty)
        let ended = life.recordingEnded(kept: true)
        #expect(ended.replies.isEmpty)
        life.captureEnded()
        #expect(life.saveEnded(ended.save!) == [7])
    }

    @Test func aQuitWithNothingRecordingOrSavingAnswersAtOnce() {
        var life = lifecycle()
        let quit = life.quitRequested(1)
        #expect(quit.stop == nil)
        #expect(quit.replies == [1])
    }

    /// A recording that ends with nothing kept starts no save, so the waiting quit answers.
    @Test func aDiscardedRecordingAnswersTheQuitWithNoSave() {
        var life = lifecycle()
        _ = life.hotkey(.record)
        life.recordingStarted(1)
        _ = life.quitRequested(1)
        let ended = life.recordingEnded(kept: false)
        #expect(ended.save == nil)
        #expect(ended.replies == [1])
    }

    /// Mid-selection, another mode's hotkey switches to it; the same mode's, the mode bar's and
    /// any press with no selection up are ignored.
    @Test func aHotkeyMidSelectionSwitchesOnlyToAnotherMode() {
        var life = lifecycle()
        #expect(life.hotkey(.area).starts)
        #expect(life.hotkey(.window).ignores)
        life.selectionBegan(.area)
        #expect(life.hotkey(.area).ignores)
        #expect(life.hotkey(.selector).ignores)
        #expect(life.switchedTo == nil)
        #expect(life.hotkey(.window).switches)
        #expect(life.switchedTo == .window)
    }
}

/// The coordinator's side of a lifecycle, driven one command at a time in any order the app
/// allows, checking each answer against the rules the app relies on.
struct LifecycleMachine {
    var life = lifecycle()
    var running = false
    var selecting: Mode?
    var recording: Int?
    var saves: [Int] = []
    /// Quits asked and not yet answered.
    var waiting: Set<Int> = []
    var nextRecording = 1
    var nextQuit = 1
    var log: [String] = []

    static let modes: [Mode] = [.area, .window, .record, .selector]

    /// The commands the app can issue in this state: a hotkey and a quit at any time, the rest
    /// in the order a capture runs them.
    var enabled: [Int] {
        let idle = running && selecting == nil && recording == nil
        return [0, 7] + (idle ? [1, 3, 5] : []) + (selecting != nil ? [2] : [])
            + (recording != nil ? [4] : []) + (saves.isEmpty ? [] : [6])
    }

    /// Runs the `pick`th enabled command with `arg`, so no generated command is wasted.
    mutating func step(_ pick: Int, _ arg: Int) {
        let kinds = enabled
        run(kinds[pick % kinds.count], arg)
    }

    mutating func run(_ kind: Int, _ arg: Int) {
        switch kind {
        case 0:
            let mode = Self.modes[arg % Self.modes.count]
            log.append("hotkey(\(mode))")
            let dispatch = life.hotkey(mode)
            if mode == .record, let recording {
                #expect(dispatch.stops == recording, "\(log)")
            } else if running {
                if let selecting, mode != selecting, mode != .selector {
                    #expect(dispatch.switches, "\(log)")
                    #expect(life.switchedTo == mode, "\(log)")
                } else {
                    #expect(dispatch.ignores, "\(log)")
                }
            } else {
                // Whatever saves are pending: a render never holds the hotkeys.
                #expect(dispatch.starts, "\(log)")
                running = true
            }
        case 1 where running && selecting == nil && recording == nil:
            let mode = Self.modes[arg % Self.modes.count]
            log.append("selectionBegan(\(mode))")
            life.selectionBegan(mode)
            selecting = mode
        case 2 where selecting != nil:
            log.append("selectionEnded")
            life.selectionEnded()
            selecting = nil
        case 3 where running && selecting == nil && recording == nil:
            log.append("recordingStarted")
            life.recordingStarted(nextRecording)
            recording = nextRecording
            nextRecording += 1
        case 4 where recording != nil:
            let kept = arg % 2 == 1
            log.append("recordingEnded(kept: \(kept))")
            recording = nil
            let ended = life.recordingEnded(kept: kept)
            #expect((ended.save != nil) == kept, "\(log)")
            if let save = ended.save {
                #expect(!saves.contains(save), "\(log)")
                saves.append(save)
            }
            answered(ended.replies)
        case 5 where running && selecting == nil && recording == nil:
            log.append("captureEnded")
            life.captureEnded()
            running = false
        case 6 where !saves.isEmpty:
            let save = saves.remove(at: arg % saves.count)
            log.append("saveEnded")
            answered(life.saveEnded(save))
        case 7:
            let quit = nextQuit
            nextQuit += 1
            log.append("quitRequested")
            waiting.insert(quit)
            let asked = life.quitRequested(quit)
            // A live recording is stopped and kept, never left running under the quit.
            #expect(asked.stop == recording, "\(log)")
            answered(asked.replies)
        default:
            return
        }
        #expect(life.running == running, "\(log)")
        #expect(life.isRecordingOrSaving == (recording != nil || !saves.isEmpty), "\(log)")
    }

    /// Quits answer only once no recording is live and no save is pending, and then every
    /// waiting quit answers, each exactly once.
    mutating func answered(_ replies: [Int]) {
        #expect(Set(replies).count == replies.count, "\(log)")
        if recording == nil && saves.isEmpty {
            #expect(Set(replies) == waiting, "\(log)")
            waiting = []
        } else {
            #expect(replies.isEmpty, "\(log)")
        }
    }

    /// Lets a live recording end kept and every save end: no quit is left unanswered.
    mutating func settle() {
        if recording != nil { run(4, 1) }
        while !saves.isEmpty { run(6, 0) }
        #expect(waiting.isEmpty, "\(log)")
    }
}

extension CaptureLifecycleTests {
    /// Any sequence of hotkeys, selections, recordings, saves and quits: a hotkey starts a
    /// capture whenever none is under way, a quit stops a live recording and answers only once
    /// it is kept and every save has ended, and every quit answers exactly once.
    @Test func anyCommandSequenceKeepsTheLifecycleRules() async {
        await propertyCheck(
            count: propertyRuns(gate: 300),
            input: zip(Gen.int(in: 0...7), Gen.int(in: 0...3)).array(of: 1...15)
        ) { commands in
            var machine = LifecycleMachine()
            for (kind, arg) in commands { machine.step(kind, arg) }
            machine.settle()
        }
    }
}
