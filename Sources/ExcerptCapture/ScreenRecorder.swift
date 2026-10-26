import CoreMedia
import ExcerptCore
import ExcerptRecording
import Foundation
import ScreenCaptureKit
import os

/// Records a region of the screen into a master: an `SCStream` of the region at 30 fps, the
/// cursor shown and Excerpt's own windows left out (as `StreamFrameSource` leaves them out),
/// each new picture appended to a `MasterWriter` on the stream's queue. Pause and Resume go
/// straight to the writer, which keeps what is on screen while paused out of the master.
///
/// A stream error or stall reaches `onFailure` once; the caller then `stop`s, so what was recorded is
/// kept. `onLimit` fires once when the recorded time reaches `maximumDuration`, on the clock
/// alone, as a still screen sends no frames.
@MainActor
public final class ScreenRecorder {
    /// Seconds of recorded time, pauses excluded, after which the recording asks to be stopped.
    public static let maximumDuration: Double = 300
    /// How often the recorded time is checked against `maximumDuration`.
    static let limitInterval: TimeInterval = 0.1

    public typealias WriterFactory =
        (_ url: URL, _ width: Int, _ height: Int, _ scale: Double, _ shortcutsLogged: Bool)
        throws -> MasterWriter

    /// Called once, on the main actor, when the stream fails or stops on its own.
    public var onFailure: ((Error) -> Void)?
    /// Called once, on the main actor, when `maximumDuration` is reached.
    public var onLimit: (() -> Void)?

    private let writerFactory: WriterFactory
    /// The writer the stream's queue appends to; nil once stopped or discarded.
    private let current = OSAllocatedUnfairLock<MasterWriter?>(initialState: nil)
    private var stream: SCStream?
    private var output: RecorderOutput?
    private var limitTimer: Timer?
    private var limitReached = false
    private var failed = false

    public init(
        writerFactory: @escaping WriterFactory = {
            try MasterWriter(
                url: $0, width: $1, height: $2, scale: $3, shortcutsLogged: $4)
        }
    ) {
        self.writerFactory = writerFactory
    }

    /// Starts writing `master` and streaming `region` into it. Throws the stream's own errors,
    /// `ScrollCaptureError.displayGone` or `.cannotExcludeExcerpt`, or the writer's, leaving no
    /// file behind.
    public func start(region: ScrollRegion, master: URL, shortcutsLogged: Bool) async throws {
        precondition(stream == nil, "one recording at a time")
        let filter = try await StreamFrameSource.ownExcludingFilter(displayID: region.displayID)
        try beginWriting(region: region, master: master, shortcutsLogged: shortcutsLogged)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.localPoints
        configuration.width = Int(region.pixelRect.width)
        configuration.height = Int(region.pixelRect.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = StreamFrameSource.colorSpaceName
        configuration.captureResolution = .best
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        let output = RecorderOutput(
            onSample: { [weak self] in self?.receive($0) },
            onError: { [weak self] in self?.streamFailed($0) })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            await discard()
            throw error
        }
        self.stream = stream
        self.output = output
    }

    /// Creates the writer and starts watching the limit: everything `start` does but the stream.
    func beginWriting(region: ScrollRegion, master: URL, shortcutsLogged: Bool) throws {
        precondition(current.withLock { $0 } == nil, "one recording at a time")
        let writer = try writerFactory(
            master, Int(region.pixelRect.width), Int(region.pixelRect.height),
            Double(region.scale), shortcutsLogged)
        current.withLock { $0 = writer }
        limitReached = false
        failed = false
        // Common modes, so the limit still fires while the control bar is being dragged.
        let timer = Timer(timeInterval: Self.limitInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLimit() }
        }
        RunLoop.main.add(timer, forMode: .common)
        limitTimer = timer
    }

    /// Appends a stream sample that carries a new picture; an unchanged screen writes nothing,
    /// and a stalled stream (the display slept or locked) fails the recording. Called on the
    /// stream's queue.
    nonisolated func receive(_ sample: CMSampleBuffer) {
        guard let status = FrameConversion.status(sample),
            let writer = current.withLock({ $0 })
        else { return }
        switch FrameConversion.content(status) {
        case .picture:
            writer.append(sample)
        case .unchanged:
            return
        case .stalled:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.streamFailed(ScrollCaptureError.streamStalled) }
            }
        }
    }

    func checkLimit() {
        guard !limitReached, let writer = current.withLock({ $0 }),
            writer.recordedTime >= Self.maximumDuration
        else { return }
        limitReached = true
        onLimit?()
    }

    /// Reports a failure once, and only while recording: a stream stopping after Stop or Discard
    /// is no failure.
    func streamFailed(_ error: Error) {
        guard !failed, current.withLock({ $0 }) != nil else { return }
        failed = true
        onFailure?(error)
    }

    public func pause() { current.withLock { $0 }?.pause() }

    public func resume() { current.withLock { $0 }?.resume() }

    /// Seconds recorded so far, pauses excluded: zero before the first frame and once stopped.
    public var recordedTime: Double { current.withLock { $0 }?.recordedTime ?? 0 }

    /// Ends the recording at this moment and stores `log` in the master. Throws what
    /// `MasterWriter.finish` throws: `RecordingError.empty` and `.recordingFailed` leave no
    /// recording, `.eventsNotSaved` leaves one without its events, for the caller to keep.
    public func stop(log: RecordingEventLog) async throws {
        let writer = end()
        // Paused, the writer's recorded time stops here, not once the stream has stopped.
        writer?.pause()
        await stopStream()
        guard let writer else { throw RecordingError.empty }
        try await writer.finish(log: log)
    }

    /// Ends the recording and deletes the master.
    public func discard() async {
        end()?.cancel()
        await stopStream()
    }

    /// Takes the writer from the stream and stops watching the limit.
    @discardableResult
    private func end() -> MasterWriter? {
        limitTimer?.invalidate()
        limitTimer = nil
        return current.withLock { writer in
            defer { writer = nil }
            return writer
        }
    }

    /// Stops the stream. A stream that can't be stopped has failed already, and what it
    /// recorded is the writer's to keep or delete, so the error is dropped.
    private func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        output = nil
    }
}

/// The recording stream's callbacks: samples go to the writer on the stream's own queue, an
/// error to the main actor.
final class RecorderOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "excerpt.recording-frames")
    private let onSample: (CMSampleBuffer) -> Void
    private let onError: @MainActor (Error) -> Void

    init(
        onSample: @escaping (CMSampleBuffer) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.onSample = onSample
        self.onError = onError
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        onSample(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError(error) } }
    }
}
