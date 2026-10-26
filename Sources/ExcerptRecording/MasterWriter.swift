import AVFoundation
import ExcerptCore
import Foundation

/// Writes a recording's master: HEVC frames in real time, with the event log in the movie's
/// metadata. Samples are host-clock stamped, as a screen stream's are. Pausing drops every
/// sample stamped before the latest `resume` that isn't already written, and shifts every later
/// one back by the time spent paused, so the master's timeline has no gap and nothing on screen
/// while paused reaches it; `recordedTime` runs on the same clock with the same pauses taken out,
/// so the events stamped with it line up with the frames.
///
/// The movie carries the log from the start — scale and whether shortcuts were logged, no events
/// — so a master whose events fail to save at `finish` still opens as a recording.
///
/// The master's width and height are rounded down to even, as HEVC needs: an odd area loses its
/// last column or row.
///
/// `@unchecked Sendable`: the stream's queue appends while the main thread pauses and stops, so
/// every touch of the writer and the state below is under `lock`, except the `finish` work after
/// the state is sealed, which no other call reaches.
public final class MasterWriter: @unchecked Sendable {
    /// The HEVC bit budget per pixel of each frame. Generous for video, because the master is
    /// mostly screen text, which must stay legible after a lossy encode and a re-render.
    public static let bitsPerPixelPerFrame = 0.25
    /// The bit rate no master goes below, however small its area.
    public static let minimumBitRate = 4_000_000
    /// The frame rate the encoder is told to expect: the stream's.
    public static let frameRate = 30

    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let header: RecordingEventLog
    private let now: @Sendable () -> CMTime
    private let writeEvents: @Sendable (RecordingEventLog, URL) async throws -> Void
    private let lock = NSLock()

    /// Source time of the first frame written: the master's zero.
    private var start: CMTime?
    private var pausedAt: CMTime?
    private var resumedAt: CMTime?
    private var pausedTotal = CMTime.zero
    private var lastWritten: CMTime?
    private var written = 0
    private var failure: String?
    private var sealed = false

    /// `scale` (pixels per point) and `shortcutsLogged` go into the master as it is created.
    public convenience init(
        url: URL, width: Int, height: Int, scale: Double, shortcutsLogged: Bool
    ) throws {
        try self.init(
            url: url, width: width, height: height, scale: scale,
            shortcutsLogged: shortcutsLogged,
            now: { CMClockGetTime(CMClockGetHostTimeClock()) },
            writeEvents: { log, url in
                try await RecordingMaster.writeMetadata(log: log, edits: nil, to: url)
            })
    }

    /// `now` stands in for the host clock samples are stamped with; `writeEvents` for the
    /// rewrite that stores the log at `finish`.
    init(
        url: URL, width: Int, height: Int, scale: Double, shortcutsLogged: Bool,
        now: @escaping @Sendable () -> CMTime,
        writeEvents: @escaping @Sendable (RecordingEventLog, URL) async throws -> Void
    ) throws {
        self.url = url
        self.now = now
        self.writeEvents = writeEvents
        header = RecordingEventLog(
            version: RecordingEventLog.version, scale: scale, shortcutsLogged: shortcutsLogged,
            events: [])
        let width = max(2, width / 2 * 2)
        let height = max(2, height / 2 * 2)
        let bitRate = max(
            Self.minimumBitRate,
            Int(Double(width * height * Self.frameRate) * Self.bitsPerPixelPerFrame))
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = try RecordingMaster.metadata(log: header, edits: nil)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: RecordingMaster.colorProperties,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                ],
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// Writes the sample's frame unless paused, finished, stamped before the latest resume, or
    /// the encoder is still busy with the last one (a real-time input drops rather than queues).
    /// A sample without an image — a stream's idle frame — writes nothing.
    public func append(_ sample: CMSampleBuffer) {
        guard let image = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        lock.withLock {
            guard !sealed, pausedAt == nil else { return }
            // Taken before Resume, delivered after it: on screen while paused, or before.
            if let resumedAt, time < resumedAt { return }
            if start == nil {
                guard writer.startWriting() else { return fail() }
                writer.startSession(atSourceTime: time)
                start = time
            }
            let shifted = time - pausedTotal
            if let lastWritten, shifted <= lastWritten { return }
            guard input.isReadyForMoreMediaData else { return }
            guard adaptor.append(image, withPresentationTime: shifted) else {
                if writer.status == .failed { fail() }
                return
            }
            lastWritten = shifted
            written += 1
        }
    }

    public func pause() {
        lock.withLock {
            if pausedAt == nil { pausedAt = now() }
        }
    }

    public func resume() {
        lock.withLock {
            guard let pausedAt else { return }
            let resumed = now()
            if start != nil { pausedTotal = pausedTotal + (resumed - pausedAt) }
            resumedAt = resumed
            self.pausedAt = nil
        }
    }

    /// Seconds recorded so far, pauses excluded: zero until the first frame, still while paused.
    public var recordedTime: Double {
        lock.withLock { recorded()?.seconds ?? 0 }
    }

    public var frameCount: Int { lock.withLock { written } }

    /// Whether a frame appended now would be taken rather than dropped as the encoder is busy.
    /// Writing starts at the first frame, so before it the input reports not ready.
    var isReadyForMoreFrames: Bool {
        lock.withLock { start == nil || input.isReadyForMoreMediaData }
    }

    /// Ends the master at the recorded time — a still screen at the end sends no frames but is
    /// still recording — and stores `log` in it. Throws `empty` (deleting the file) when no frame
    /// was written, `recordingFailed` (deleting it) when the writer failed or the recording was
    /// already stopped, and `eventsNotSaved` when the master is saved but the rewrite storing
    /// `log` failed: it then opens with no events, and the caller keeps it.
    public func finish(log: RecordingEventLog) async throws {
        enum Outcome {
            case end(CMTime)
            case empty
            case failed(String)
            case stopped
        }
        let outcome: Outcome = lock.withLock {
            if let failure { return .failed(failure) }
            if sealed { return .stopped }
            sealed = true
            guard let start, let lastWritten, let recorded = recorded() else { return .empty }
            guard writer.status == .writing else { return .failed(writerFailure()) }
            let frame = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
            return .end(CMTimeMaximum(start + recorded, lastWritten + frame))
        }
        let end: CMTime
        switch outcome {
        case .end(let time): end = time
        case .stopped: throw RecordingError.recordingFailed("The recording was already stopped.")
        case .empty:
            discard()
            throw RecordingError.empty
        case .failed(let reason):
            discard()
            throw RecordingError.recordingFailed(reason)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            let reason = writerFailure()
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.recordingFailed(reason)
        }
        guard log != header else { return }
        do {
            try await writeEvents(log, url)
        } catch {
            throw RecordingError.eventsNotSaved(error.localizedDescription)
        }
    }

    /// Stops writing and deletes the file.
    public func cancel() {
        lock.withLock { sealed = true }
        discard()
    }

    private func discard() {
        lock.withLock {
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Records the writer's failure and stops taking frames. Called under `lock`.
    private func fail() {
        failure = writerFailure()
        sealed = true
    }

    private func writerFailure() -> String {
        writer.error?.localizedDescription ?? "The movie writer stopped."
    }

    /// Recorded time as a duration from `start`; nil before the first frame. Called under `lock`.
    private func recorded() -> CMTime? {
        guard let start else { return nil }
        let recorded = (pausedAt ?? now()) - start - pausedTotal
        return CMTimeMaximum(recorded, .zero)
    }
}
