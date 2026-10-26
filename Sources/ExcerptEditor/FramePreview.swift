import AVFoundation
import ExcerptCore
import ExcerptRecording

/// The master's frame at a time, rendered with the edits through `RecordingRenderer`, the
/// renderer that writes the primary. Only the latest request renders: one asked for while
/// another is rendering replaces any still waiting, so scrubbing and playback never queue.
@MainActor
final class FramePreview {
    private let generator: AVAssetImageGenerator
    private let log: RecordingEventLog
    /// The last frame decoded, kept so a change of edits re-renders without decoding.
    private var decoded: (time: Double, image: CGImage)?
    private var pending: (request: Request, edits: RecordingEdits)?
    private var busy = false
    /// Each request's render, or nil when its frame couldn't be decoded.
    var onFrame: (CGImage?) -> Void = { _ in }

    /// `frame` is when to decode the frame (`RecordingEditorModel.previewFrameTime`, so the
    /// frame shown is the one the model's spans are set from); `render` is the playhead, which
    /// the clicks, shortcut pill and blur spans are drawn for.
    struct Request: Equatable {
        let frame: Double
        let render: Double
    }

    init(master: RecordingMaster) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: master.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        log = master.log
    }

    func request(_ request: Request, edits: RecordingEdits) {
        pending = (request, edits)
        guard !busy else { return }
        busy = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            guard let frame = await frame(at: next.request.frame) else {
                onFrame(nil)
                continue
            }
            let log = log
            let t = next.request.render
            let rendered = await Task.detached(priority: .userInitiated) {
                RecordingRenderer.render(frame, at: t, log: log, edits: next.edits, outputScale: 1)
            }.value
            onFrame(rendered)
        }
        busy = false
    }

    private func frame(at t: Double) async -> CGImage? {
        if let decoded, decoded.time == t { return decoded.image }
        let time = CMTime(seconds: t, preferredTimescale: 1_000_000)
        guard let image = try? await generator.image(at: time).image else { return nil }
        decoded = (t, image)
        return image
    }
}
