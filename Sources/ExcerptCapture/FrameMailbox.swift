import ExcerptCore

/// Frames of the scrolling region, newest first: what the scroll driver reads.
@MainActor
public protocol FrameSource: AnyObject {
    /// The next frame delivered after the last one read: the newest waiting frame at once, or
    /// the next to arrive within `timeout`. Returns nil only when the stream is alive and no
    /// frame arrived — an unchanged screen. Throws once the stream has failed or stopped, and
    /// when the waiting task is cancelled; a dead stream never reads as an unchanged screen.
    func nextFrame(timeout: Duration) async throws -> PixelBuffer?
    /// Drops any frame waiting to be read, so the next read is newer than this call.
    func discardWaiting()
}

/// Hands frames from a stream to one reader at a time. Keeps only the newest unread frame: a
/// reader that falls behind skips to the present instead of working through a backlog. Every
/// wait is resumed exactly once — by a frame, a failure, its own timeout or cancellation,
/// whichever comes first — and a timeout left over from an earlier wait never resumes a later
/// one.
@MainActor
public final class FrameMailbox: FrameSource {
    /// Suspends for a duration; replaced in tests by a clock the test fires by hand.
    public typealias Sleep = @MainActor (Duration) async throws -> Void

    private var waiting: PixelBuffer?
    private var reader: CheckedContinuation<PixelBuffer?, Error>?
    private var timer: Task<Void, Never>?
    private var readerID = 0
    private var failure: Error?
    private let sleep: Sleep

    var isWaiting: Bool { reader != nil }

    public init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func deliver(_ frame: PixelBuffer) {
        guard failure == nil else { return }
        if reader != nil {
            resume(readerID, with: .success(frame))
        } else {
            waiting = frame
        }
    }

    /// The stream stopped: the reader waiting now, and every later read, gets `error`.
    public func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        waiting = nil
        resume(readerID, with: .failure(error))
    }

    public func nextFrame(timeout: Duration) async throws -> PixelBuffer? {
        if let failure { throw failure }
        try Task.checkCancellation()
        if let frame = waiting {
            waiting = nil
            return frame
        }
        precondition(reader == nil, "FrameMailbox has one reader at a time")
        readerID += 1
        let id = readerID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader = continuation
                timer = Task { @MainActor [weak self] in
                    guard let sleep = self?.sleep else { return }
                    do {
                        try await sleep(timeout)
                    } catch {
                        return  // the wait ended first and cancelled this timer
                    }
                    self?.resume(id, with: .success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resume(id, with: .failure(CancellationError()))
            }
        }
    }

    public func discardWaiting() { waiting = nil }

    private func resume(_ id: Int, with result: Result<PixelBuffer?, Error>) {
        guard id == readerID, let reader else { return }
        self.reader = nil
        timer?.cancel()
        timer = nil
        reader.resume(with: result)
    }
}
