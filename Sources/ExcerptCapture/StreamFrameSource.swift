import CoreMedia
import ExcerptCore
import Foundation
import ScreenCaptureKit

/// Live frames of the scrolling region from an `SCStream`, without any of Excerpt's windows (so
/// the HUD and preview never appear in a frame) and without the cursor. The stream excludes
/// Excerpt by application, because the HUD is created after it starts; that filter form can't
/// also exclude Finder's desktop icons the way `ScreenCapturer`'s stills do, so icons under the
/// region appear in frames.
@MainActor
public final class StreamFrameSource: FrameSource {
    private let mailbox = FrameMailbox()
    private var stream: SCStream?
    private var output: StreamOutput?
    /// Called once, on the main actor, when the stream fails or stops on its own. A capture that
    /// is halted reads no frames, so this is how the failure reaches it.
    public var onFailure: ((Error) -> Void)?

    public init() {}

    nonisolated static var colorSpaceName: CFString { PixelBuffer.colorSpace.name! }

    public func start(region: ScrollRegion) async throws {
        precondition(stream == nil, "one stream per source: stop it before starting another")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
        else { throw ScrollCaptureError.displayGone }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        guard !own.isEmpty else { throw ScrollCaptureError.cannotExcludeExcerpt }
        let filter = SCContentFilter(
            display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.localPoints
        configuration.width = Int(region.pixelRect.width)
        configuration.height = Int(region.pixelRect.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = Self.colorSpaceName
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        let mailbox = self.mailbox
        let output = StreamOutput(
            onFrame: { mailbox.deliver($0) },
            onError: { [weak self] error in
                guard !mailbox.hasFailed else { return }
                mailbox.fail(error)
                self?.onFailure?(error)
            })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    /// Stops the stream. Throws when it could not be stopped, unless the stream had already
    /// failed on its own: that error reached the mailbox through `didStopWithError`. A throw
    /// after the capture already ended is the caller's to report as a non-fatal note: the
    /// stitch is already saved.
    public func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        defer { output = nil }
        do {
            try await stream.stopCapture()
        } catch {
            if !mailbox.hasFailed { throw error }
        }
    }

    public func nextFrame(timeout: Duration) async throws -> PixelBuffer? {
        try await mailbox.nextFrame(timeout: timeout)
    }
}

/// The stream's callbacks, on its own queue: converts each frame there, then hands it to the
/// main actor in arrival order.
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "excerpt.scroll-frames")
    private let onFrame: @MainActor (PixelBuffer) -> Void
    private let onError: @MainActor (Error) -> Void

    init(
        onFrame: @escaping @MainActor (PixelBuffer) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, let status = FrameConversion.status(sampleBuffer) else { return }
        switch FrameConversion.content(status) {
        case .picture:
            guard let frame = FrameConversion.pixels(sampleBuffer) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFrame(frame) } }
        case .unchanged:
            return
        case .stalled:
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onError(ScrollCaptureError.streamStalled) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError(error) } }
    }
}

enum FrameConversion {
    /// What a stream sample says about the region.
    enum SampleContent: Equatable {
        /// A new picture of the region.
        case picture
        /// The region hasn't changed since the last picture.
        case unchanged
        /// The stream stopped sending pictures (the display slept or locked): never "unchanged",
        /// which would read as the page's end.
        case stalled
    }

    /// The first frame after the stream starts is `.started`, every later new picture
    /// `.complete`; idle and blank samples mean nothing changed; a suspended or stopped stream
    /// has stalled.
    static func content(_ status: SCFrameStatus) -> SampleContent {
        switch status {
        case .complete, .started: .picture
        case .suspended, .stopped: .stalled
        case .idle, .blank: .unchanged
        @unknown default: .unchanged
        }
    }

    /// The sample's frame status; nil for a sample without one.
    static func status(_ sample: CMSampleBuffer) -> SCFrameStatus? {
        guard sample.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// The pixels of a sample that carries a picture.
    static func pixels(_ sample: CMSampleBuffer) -> PixelBuffer? {
        guard let image = sample.imageBuffer else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        let height = CVPixelBufferGetHeight(image)
        return pixelBuffer(
            bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
            width: CVPixelBufferGetWidth(image), height: height, bytesPerRow: bytesPerRow)
    }

    /// Premultiplied BGRA rows, possibly padded past `width`, in Core's RGBA layout: the same
    /// values reordered, so equal screens give equal buffers.
    static func pixelBuffer(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int)
        -> PixelBuffer
    {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * bytesPerRow + x * 4
                let d = (y * width + x) * 4
                bytes[d] = bgra[s + 2]
                bytes[d + 1] = bgra[s + 1]
                bytes[d + 2] = bgra[s]
                bytes[d + 3] = bgra[s + 3]
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }
}
