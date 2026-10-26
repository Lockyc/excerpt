import AVFoundation
import ExcerptCore
import Foundation

public struct ExportResult: Sendable {
    public let url: URL
    public let format: RecordingFormat
    /// The edits asked for a GIF, but none fitted the byte budget, so this is an MP4.
    public let fellBackToMP4: Bool
}

/// Renders a recording's primary from its master and edits.
public enum RecordingExporter {
    /// GIF frame rates tried in turn; past the last, the primary is an MP4.
    static let gifRates = [15, 10]
    static let mp4Rate = 30
    /// A frame stamped this close after a sample time counts as on screen at it, so rounding in
    /// the two clocks never shows the frame before: frame `k` is rendered at every time from
    /// its stamp less this up to the next frame's stamp less this.
    public static let frameTolerance = 0.0005

    /// Writes the primary `edits.format` asks for, every frame through `RecordingRenderer`: a
    /// GIF at 1×, at the first of `gifRates` that fits `byteBudget`, else an MP4; or an MP4 at
    /// the master's size rounded down to even. Replaces any primary already there and deletes
    /// the other format's. Throws `exportFailed` when the trim keeps none of the master.
    public static func export(
        _ master: RecordingMaster, edits: RecordingEdits, to paths: RecordingPaths,
        byteBudget: Int = GIFEncoder.byteBudget
    ) async throws -> ExportResult {
        let start = max(0, edits.trim.lowerBound)
        let end = min(master.duration, edits.trim.upperBound)
        guard start < end else {
            throw RecordingError.exportFailed("The trim keeps none of the recording.")
        }
        let trim = start...end
        if edits.format == .gif {
            for fps in gifRates {
                guard
                    let data = try await gif(
                        master, edits: edits, trim: trim, fps: fps, byteBudget: byteBudget)
                else { continue }
                try await place(.gif, in: paths) { try data.write(to: $0) }
                return ExportResult(url: paths.primary(.gif), format: .gif, fellBackToMP4: false)
            }
        }
        try await place(.mp4, in: paths) {
            try await mp4(master, edits: edits, trim: trim, to: $0)
        }
        return ExportResult(
            url: paths.primary(.mp4), format: .mp4, fellBackToMP4: edits.format == .gif)
    }

    /// Writes through a file beside the primary, moved into place once whole, then deletes the
    /// other format's primary: the library files a recording by whichever one it finds.
    private static func place(
        _ format: RecordingFormat, in paths: RecordingPaths,
        write: (URL) async throws -> Void
    ) async throws {
        let destination = paths.primary(format)
        let temporary = temporaryURL(beside: destination)
        do {
            try await write(temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let other: RecordingFormat = format == .gif ? .mp4 : .gif
        try? FileManager.default.removeItem(at: paths.primary(other))
    }

    /// The GIF at `fps`, or nil as soon as it is over `byteBudget`.
    private static func gif(
        _ master: RecordingMaster, edits: RecordingEdits, trim: ClosedRange<Double>, fps: Int,
        byteBudget: Int
    ) async throws -> Data? {
        let reader = try await FrameReader(master, range: trim)
        defer { reader.cancel() }
        var encoder: GIFEncoder?
        for sample in samples(over: trim, fps: fps) {
            try Task.checkCancellation()
            let frame = PixelBuffer(
                RecordingRenderer.render(
                    try reader.frame(at: sample.time), at: sample.time, log: master.log,
                    edits: edits, outputScale: 1 / master.log.scale))
            if encoder == nil { encoder = GIFEncoder(width: frame.width, height: frame.height) }
            encoder!.add(frame, delay: sample.delay)
            if encoder!.byteCount > byteBudget { return nil }
        }
        let data = encoder!.finish()
        return data.count > byteBudget ? nil : data
    }

    /// Sample times `1 / fps` apart from the trim's start, each with its delay in centiseconds.
    /// Delays are differences of rounded cumulative times, so the clip runs exactly the trim's
    /// length however `fps` divides it.
    static func samples(over trim: ClosedRange<Double>, fps: Int) -> [(
        time: Double, delay: Int
    )] {
        let total = max(1, Int(((trim.upperBound - trim.lowerBound) * 100).rounded()))
        func centiseconds(_ index: Int) -> Int {
            min(total, Int((Double(index) * 100 / Double(fps)).rounded()))
        }
        var samples: [(time: Double, delay: Int)] = []
        var index = 0
        while centiseconds(index) < total {
            samples.append(
                (
                    trim.lowerBound + Double(index) / Double(fps),
                    centiseconds(index + 1) - centiseconds(index)
                ))
            index += 1
        }
        return samples
    }

    /// The H.264 MP4 at `mp4Rate`, at the master's pixel size rounded down to even.
    private static func mp4(
        _ master: RecordingMaster, edits: RecordingEdits, trim: ClosedRange<Double>, to url: URL
    ) async throws {
        let width = max(2, Int(master.pixelSize.width) / 2 * 2)
        let height = max(2, Int(master.pixelSize.height) / 2 * 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: RecordingMaster.colorProperties,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw failure(writer) }
        writer.startSession(atSourceTime: .zero)
        let encode = MP4Encode(
            reader: try await FrameReader(master, range: trim), adaptor: adaptor,
            times: samples(over: trim, fps: mp4Rate).map(\.time), start: trim.lowerBound
        ) { frame, time in
            RecordingRenderer.render(
                frame, at: time, log: master.log, edits: edits, outputScale: 1)
        }
        do {
            try await encode.run()
        } catch {
            writer.cancelWriting()
            throw error
        }
        writer.endSession(
            atSourceTime: CMTime(
                seconds: trim.upperBound - trim.lowerBound, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure(writer) }
    }

    private static func failure(_ writer: AVAssetWriter) -> RecordingError {
        .exportFailed(writer.error?.localizedDescription ?? "The video couldn't be written.")
    }
}

/// One MP4 encode, pulled by its writer input: each time the input wants frames it reads,
/// renders and appends until full, then waits to be asked again.
///
/// `@unchecked Sendable`: AVFoundation calls the pull block on `queue` alone, and nothing else
/// touches the reader, adaptor or `index` while `run` is pending.
private final class MP4Encode: @unchecked Sendable {
    private let reader: FrameReader
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let times: [Double]
    private let start: Double
    private let render: (CGImage, Double) -> CGImage
    private let queue = DispatchQueue(label: "excerpt.recording.mp4")
    private var index = 0
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        reader: FrameReader, adaptor: AVAssetWriterInputPixelBufferAdaptor, times: [Double],
        start: Double, render: @escaping (CGImage, Double) -> CGImage
    ) {
        self.reader = reader
        self.adaptor = adaptor
        self.times = times
        self.start = start
        self.render = render
    }

    func run() async throws {
        defer { reader.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            adaptor.assetWriterInput.requestMediaDataWhenReady(on: queue) { [self] in pull() }
        }
    }

    private func pull() {
        let input = adaptor.assetWriterInput
        while continuation != nil && input.isReadyForMoreMediaData {
            guard index < times.count else { return end(nil) }
            do {
                let time = times[index]
                let pixels = try draw(render(try reader.frame(at: time), time))
                let pts = CMTime(
                    value: CMTimeValue(index), timescale: CMTimeScale(RecordingExporter.mp4Rate))
                guard adaptor.append(pixels, withPresentationTime: pts) else {
                    throw RecordingError.exportFailed("The video couldn't be written.")
                }
                index += 1
            } catch {
                return end(error)
            }
        }
    }

    private func end(_ error: Error?) {
        adaptor.assetWriterInput.markAsFinished()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }

    /// The frame in a buffer from the writer's pool, top-left aligned: a frame larger than the
    /// video loses its last column or row.
    private func draw(_ frame: CGImage) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
            let buffer = made
        else { throw RecordingError.exportFailed("The video couldn't be written.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: PixelBuffer.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(
            frame,
            in: CGRect(
                x: 0, y: height - frame.height, width: frame.width, height: frame.height))
        return buffer
    }
}

/// Reads a master's frames in order over a range, handing back the frame on screen at each
/// time asked for. Times must not go backwards.
final class FrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var upcoming: CMSampleBuffer?
    private var image: CGImage?

    init(_ master: RecordingMaster, range: ClosedRange<Double>) async throws {
        let asset = AVURLAsset(url: master.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.unreadableMaster(master.url)
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        guard reader.startReading() else {
            throw RecordingError.exportFailed(
                reader.error?.localizedDescription ?? "The recording couldn't be read.")
        }
        upcoming = nextFrame()
    }

    /// The latest frame stamped at or before `t`, or the first frame read when none is.
    func frame(at t: Double) throws -> CGImage {
        while let next = upcoming,
            current == nil
                || next.presentationTimeStamp.seconds <= t + RecordingExporter.frameTolerance
        {
            current = next
            image = nil
            upcoming = nextFrame()
        }
        if reader.status == .failed {
            throw RecordingError.exportFailed(
                reader.error?.localizedDescription ?? "The recording couldn't be read.")
        }
        guard let current, let buffer = current.imageBuffer else {
            throw RecordingError.exportFailed("The recording has no frames to export.")
        }
        if let image { return image }
        let made = Self.image(buffer)
        image = made
        return made
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }

    private func nextFrame() -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            if sample.imageBuffer != nil { return sample }
        }
        return nil
    }

    /// A copy of the BGRA frame, so it outlives the reader's buffer.
    private static func image(_ buffer: CVPixelBuffer) -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: rowBytes * height)
        return CGImage(
            width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: rowBytes, space: PixelBuffer.colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }
}
