import ExcerptCore
import Foundation

/// Scrolls the page under the region.
@MainActor
public protocol Scroller: AnyObject {
    /// Why a scroll step can't be posted now, read live before every step: `.accessibility`
    /// when Excerpt lacks Accessibility access, `.pointerMoved` when the pointer is outside the
    /// region and off the HUD, or couldn't be moved there (wheel events go to the window under
    /// it). Nil when a
    /// step can be posted.
    var blocker: ManualReason? { get }
    /// The pointer rests on the HUD, on its way to Done or Cancel: a step would scroll the HUD,
    /// so auto-scroll holds until the pointer leaves it.
    var waits: Bool { get }
    /// Scrolls the page down by `points`; false when the wheel event couldn't be made.
    func scroll(points: Double) -> Bool
}

/// How a scrolling capture starts: Excerpt scrolling the page, or the user.
public enum ScrollStart: Sendable { case auto, manual }

public enum ScrollOutcome {
    case saved(PixelBuffer)
    case cancelled
    /// The stream failed or stopped. `partial` is what was stitched before it did, for the app
    /// to save and say so; nil when no frame came.
    case failed(Error, partial: PixelBuffer?)
}

public enum ScrollCaptureError: Error, Equatable, LocalizedError {
    case noFrames
    case displayGone
    case displayChanged
    case cannotExcludeExcerpt
    case streamStalled

    public var errorDescription: String? {
        switch self {
        case .noFrames: "The screen sent no picture of the region."
        case .displayGone: "The display the region was on is no longer connected."
        case .displayChanged: "The displays changed during the capture."
        case .cannotExcludeExcerpt: "Excerpt couldn't keep its own windows out of the capture."
        case .streamStalled:
            "The screen stopped sending pictures, as it does when the display sleeps or locks."
        }
    }
}

/// Runs one scrolling capture: scroll a step, wait for the frame to settle, stitch, and repeat
/// until the session says stop; or sample frames while the user scrolls. `finish()` (Return,
/// Done) saves what is stitched; `cancel()` (Esc, Cancel) discards it and ends any wait for a
/// frame at once. `run()` returns once on every path, and the caller that started the frame
/// source stops it then.
@MainActor
public final class ScrollCapture {
    /// The longest wait for the page to answer a scroll step: an app can move it well after the
    /// wheel event, and a step that shows no movement in time counts towards the page's end.
    public static let responseTime: Duration = .seconds(2)
    /// The longest wait for a moving page to settle once it has answered a step.
    public static let settleTime: Duration = .milliseconds(300)
    public static let firstFrameTimeout: Duration = .seconds(3)
    /// How long a manual-mode read waits before checking for Return or Esc again.
    public static let sampleTimeout: Duration = .milliseconds(500)
    /// How often auto-scroll looks again while the scroller `waits`.
    public static let holdPoll: Duration = .milliseconds(100)

    private enum Request { case finish, cancel }

    private let source: FrameSource
    private let scroller: Scroller
    private let stepPoints: Double
    private let scale: Double
    private let maximumHeight: Int
    private let start: ScrollStart
    /// The user scrolled since the loop last looked.
    private var tookOver = false
    private var request: Request?
    private var waker: CheckedContinuation<Void, Never>?
    /// The read in flight, which `cancel()` ends.
    private var reading: Task<PixelBuffer?, Error>?
    private var running = false
    /// Called with the session after every change, on the main actor.
    public var onChange: ((ScrollSession) -> Void)?

    public init(
        source: FrameSource, scroller: Scroller, stepPoints: Double, scale: Double,
        maximumHeight: Int = Stitcher.defaultMaximumHeight, start: ScrollStart = .auto
    ) {
        self.source = source
        self.scroller = scroller
        self.stepPoints = stepPoints
        self.scale = scale
        self.maximumHeight = maximumHeight
        self.start = start
    }

    /// The user scrolled the page (a wheel event over the region that Excerpt didn't post): they
    /// scroll from here. Wakes a stopped capture, so scrolling back to where the stitch ends
    /// picks it up again.
    public func userScrolled() {
        tookOver = true
        let waiting = waker
        waker = nil
        waiting?.resume()
    }

    public func finish() { stop(.finish) }
    public func cancel() { stop(.cancel) }

    /// The first request wins: Return then Esc saves. Finishing lets a read in flight end on
    /// its own, so the frame it brings is stitched; cancelling ends it now. Finishing while a
    /// short step waits for the next to confirm the page ended keeps that frame
    /// (`ScrollSession.finish()`).
    private func stop(_ next: Request) {
        if request == nil { request = next }
        if request == .cancel { reading?.cancel() }
        let waiting = waker
        waker = nil
        waiting?.resume()
    }

    /// Runs the capture to its end; call it once. Cancelling the task running it is `cancel()`.
    public func run() async -> ScrollOutcome {
        precondition(!running, "ScrollCapture runs one capture at a time")
        running = true
        return await withTaskCancellationHandler {
            await capture()
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func capture() async -> ScrollOutcome {
        let first: PixelBuffer
        do {
            guard let frame = try await read(timeout: Self.firstFrameTimeout) else {
                return request == .cancel
                    ? .cancelled : .failed(ScrollCaptureError.noFrames, partial: nil)
            }
            first = frame
        } catch {
            return request == .cancel ? .cancelled : .failed(error, partial: nil)
        }
        var session = ScrollSession(
            first: first, scale: scale, canAutoScroll: true, maximumHeight: maximumHeight)
        if start == .manual {
            session.takeOver()
        } else if let blocker = scroller.blocker {
            session.fallBack(blocker)
        }
        let travel = Int((stepPoints * scale).rounded())
        var latest = first
        onChange?(session)
        while true {
            switch request {
            case .finish:
                session.finish()
                return .saved(session.stitcher.image)
            case .cancel: return .cancelled
            case nil: break
            }
            if tookOver {
                tookOver = false
                session.takeOver()
                onChange?(session)
            }
            do {
                switch session.phase {
                case .auto:
                    if scroller.waits {
                        try? await Task.sleep(for: Self.holdPoll)
                        continue
                    }
                    if let blocker = scroller.blocker {
                        session.fallBack(blocker)
                    } else {
                        if scroller.scroll(points: stepPoints) {
                            latest = try await settledFrame(after: latest)
                            // A step the user scrolled through is not measured against its
                            // travel: they take over, and the frame it settled on is their
                            // first, so a flick past a screen still has a frame to bridge it.
                            if tookOver {
                                tookOver = false
                                session.takeOver()
                                session.sampled(latest)
                            } else {
                                session.stepped(latest, travel: travel)
                            }
                        } else {
                            session.fallBack(.eventFailed)
                        }
                    }
                    onChange?(session)
                case .manual:
                    if let frame = try await read(timeout: Self.sampleTimeout) {
                        session.sampled(frame)
                        onChange?(session)
                    }
                case .halted:
                    if !tookOver { await waitForRequest() }
                case .finished:
                    return .saved(session.stitcher.image)
                }
            } catch {
                // A failed or stopped stream is never "nothing changed": it ends the capture,
                // keeping the stitch, unless the user already asked to end it.
                switch request {
                case .finish:
                    session.finish()
                    return .saved(session.stitcher.image)
                case .cancel: return .cancelled
                case nil: return .failed(error, partial: session.stitcher.image)
                }
            }
        }
    }

    /// The frame once the page has settled after a step. First the page answers: reads run for
    /// up to `responseTime` until a frame isn't still against `previous` (a caret's blink is);
    /// none means the page didn't move: the newest frame read, else `previous` again. The first
    /// read is any frame that arrived since the last one read: where a step that moved for
    /// longer than `settleTime` came to rest, so the stitch catches up with it. Then it settles:
    /// two identical frames in a row, or the newest frame when `settleTime` runs out. A failing
    /// stream throws.
    func settledFrame(after previous: PixelBuffer) async throws -> PixelBuffer {
        let clock = ContinuousClock()
        let ignored = StitchMatcher.ignoredRightColumns(width: previous.width, scale: scale)
        let answered = clock.now + Self.responseTime
        var newest: PixelBuffer?
        while true {
            guard answered > clock.now,
                let frame = try await read(timeout: answered - clock.now)
            else { return newest ?? previous }
            newest = frame
            if StitchMatcher.match(previous, frame, ignoringRightColumns: ignored) != .still {
                break
            }
        }
        let deadline = clock.now + Self.settleTime
        while deadline > clock.now {
            guard let frame = try await read(timeout: deadline - clock.now) else { break }
            if frame == newest { return frame }
            newest = frame
        }
        return newest ?? previous
    }

    /// One read from the source, in a task `cancel()` can end.
    private func read(timeout: Duration) async throws -> PixelBuffer? {
        if request == .cancel { throw CancellationError() }
        let task = Task { [source] in try await source.nextFrame(timeout: timeout) }
        reading = task
        defer { reading = nil }
        return try await task.value
    }

    private func waitForRequest() async {
        guard request == nil else { return }
        await withCheckedContinuation { waker = $0 }
    }
}
