import AVFoundation
import ExcerptCore
import Foundation

/// Writes a recording's master: HEVC frames in real time, then the event log in the movie's
/// metadata. Samples are host-clock stamped, as a screen stream's are. Pausing drops what
/// arrives until `resume`, and every later sample is shifted back by the time spent paused, so
/// the master's timeline has no gap; `recordedTime` runs on the same clock with the same pauses
/// taken out, so the events stamped with it line up with the frames.
///
/// The master's width and height are rounded down to even, as HEVC needs: an odd area loses its
/// last column or row.
///
/// `@unchecked Sendable`: the stream's queue appends while the main thread pauses and stops, so
/// every touch of the writer and the state below is under `lock`, except the `finish` work after
/// the state is sealed, which no other call reaches.
public final class MasterWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let now: @Sendable () -> CMTime
    private let lock = NSLock()

    /// Source time of the first frame written: the master's zero.
    private var start: CMTime?
    private var pausedAt: CMTime?
    private var pausedTotal = CMTime.zero
    private var lastWritten: CMTime?
    private var written = 0
    private var sealed = false

    public convenience init(url: URL, width: Int, height: Int) throws {
        try self.init(
            url: url, width: width, height: height,
            now: { CMClockGetTime(CMClockGetHostTimeClock()) })
    }

    /// `now` stands in for the host clock samples are stamped with.
    init(url: URL, width: Int, height: Int, now: @escaping @Sendable () -> CMTime) throws {
        self.url = url
        self.now = now
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: max(2, width / 2 * 2),
                AVVideoHeightKey: max(2, height / 2 * 2),
                AVVideoColorPropertiesKey: RecordingMaster.colorProperties,
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// Writes the sample's frame unless paused, finished, or the encoder is still busy with the
    /// last one (a real-time input drops rather than queues). A sample without an image — a
    /// stream's idle frame — writes nothing.
    public func append(_ sample: CMSampleBuffer) {
        guard let image = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        lock.withLock {
            guard !sealed, pausedAt == nil else { return }
            if start == nil {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: time)
                start = time
            }
            let shifted = time - pausedTotal
            // A frame taken before Resume but delivered after it would land behind the last one.
            if let lastWritten, shifted <= lastWritten { return }
            guard input.isReadyForMoreMediaData,
                adaptor.append(image, withPresentationTime: shifted)
            else { return }
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
            if start != nil { pausedTotal = pausedTotal + (now() - pausedAt) }
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
    /// still recording — and stores `log` in it. With no frame written, deletes the file and
    /// throws `RecordingError.empty`.
    public func finish(log: RecordingEventLog) async throws {
        let end: CMTime? = lock.withLock {
            sealed = true
            guard let start, let lastWritten, let recorded = recorded() else { return nil }
            let frame = CMTime(value: 1, timescale: 30)
            return CMTimeMaximum(start + recorded, lastWritten + frame)
        }
        guard let end else {
            cancel()
            throw RecordingError.empty
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.exportFailed(
                writer.error?.localizedDescription ?? "The recording couldn't be saved.")
        }
        try await RecordingMaster.writeMetadata(log: log, edits: nil, to: url)
    }

    /// Stops writing and deletes the file.
    public func cancel() {
        lock.withLock {
            sealed = true
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Recorded time as a duration from `start`; nil before the first frame. Called under `lock`.
    private func recorded() -> CMTime? {
        guard let start else { return nil }
        let recorded = (pausedAt ?? now()) - start - pausedTotal
        return CMTimeMaximum(recorded, .zero)
    }
}
