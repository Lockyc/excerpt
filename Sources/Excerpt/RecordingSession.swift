import AVFoundation
import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptRecording
import ImageIO

/// One recording from countdown to a readable master: the 3-2-1 countdown, then the recorder,
/// the event logger and the control bar together until Stop, Discard, the time limit or a
/// failure. No key is taken system-wide; the control bar, the menu-bar item and the Record
/// hotkey (through `stop`) end it.
@MainActor
final class RecordingSession {
    enum Outcome {
        /// The master is saved and read back. `stoppedEarly` is why the recording ended before
        /// it was stopped; `eventsSaved` is false when the shortcuts and clicks were lost.
        case saved(RecordingMaster, stoppedEarly: Error?, eventsSaved: Bool)
        /// Discarded, cancelled in the countdown, or stopped before the first frame was asked
        /// for: nothing is left on disk.
        case discarded
        /// Nothing was saved; `RecordingError.empty` when no frame was recorded.
        case failed(Error)
    }

    /// Called about four times a second while recording with the recorded seconds.
    var onTick: (Double) -> Void = { _ in }

    private let region: ScrollRegion
    private let paths: RecordingPaths
    private let frontmostPID: pid_t?
    private let ownHotKeys: [HotKeyBinding]
    private let recorder = ScreenRecorder()
    private let chrome: RecordingChrome
    private var paused = false
    private var end: End?
    private var waiting: CheckedContinuation<Void, Never>?

    /// How the recording was asked to end: the first request wins.
    private enum End {
        case stop
        case discard
        case stopped(Error)
    }

    init(
        region: ScrollRegion, paths: RecordingPaths, frontmostPID: pid_t?,
        ownHotKeys: [HotKeyBinding]
    ) {
        self.region = region
        self.paths = paths
        self.frontmostPID = frontmostPID
        self.ownHotKeys = ownHotKeys
        chrome = RecordingChrome(area: region.appKitFrame)
    }

    func run() async -> Outcome {
        defer { chrome.close() }
        // Stopped in the countdown: nothing was recorded, so nothing is kept.
        guard await chrome.countdown(), end == nil else { return .discarded }
        let shortcutsLogged = InputMonitoring.hasPermission()
        let recorder = recorder
        let logger = EventLogger(
            region: region, frontmostPID: frontmostPID, ownHotKeys: ownHotKeys,
            clock: { [weak self] in
                guard let self, !self.paused else { return nil }
                return recorder.recordedTime
            }, hasInputMonitoring: shortcutsLogged)
        do {
            try await recorder.start(
                region: region, master: paths.master, shortcutsLogged: shortcutsLogged)
        } catch {
            return .failed(error)
        }
        // Stopped or discarded while the stream started: the chrome stays closed.
        let log = end == nil ? await recordUntilEnded(logger) : logger.stop()

        var stoppedEarly: Error?
        switch end {
        case .discard:
            await recorder.discard()
            return .discarded
        case .stopped(let error): stoppedEarly = error
        case .stop, nil: break
        }
        var eventsSaved = true
        do {
            try await recorder.stop(log: log)
        } catch RecordingError.eventsNotSaved {
            eventsSaved = false
        } catch {
            return .failed(error)
        }
        do {
            let master = try await RecordingMaster.read(paths.master)
            return .saved(master, stoppedEarly: stoppedEarly, eventsSaved: eventsSaved)
        } catch {
            return .failed(error)
        }
    }

    /// Shows the outline and control bar and logs events until the first end request, then
    /// takes the chrome down; returns what was logged.
    private func recordUntilEnded(_ logger: EventLogger) async -> RecordingEventLog {
        let recorder = recorder
        recorder.onFailure = { [weak self] in self?.finish(.stopped($0)) }
        recorder.onLimit = { [weak self] in self?.finish(.stop) }
        chrome.onPause = { [weak self] in
            self?.paused = true
            recorder.pause()
        }
        chrome.onResume = { [weak self] in
            self?.paused = false
            recorder.resume()
        }
        chrome.onStop = { [weak self] in self?.finish(.stop) }
        chrome.onDiscard = { [weak self] in self?.finish(.discard) }
        logger.start()
        chrome.showRecording()
        tick()
        // Common modes, so the time runs on while the control bar is dragged.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // The area no longer matches the screen once the displays change.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.stopped(ScrollCaptureError.displayChanged)) }
        }
        if end == nil { await withCheckedContinuation { waiting = $0 } }
        NotificationCenter.default.removeObserver(observer)
        timer.invalidate()
        let log = logger.stop()
        chrome.close()
        recorder.onFailure = nil
        recorder.onLimit = nil
        return log
    }

    /// Ends the recording and keeps it; in the countdown, cancels it.
    func stop() { finish(.stop) }

    private func finish(_ requested: End) {
        guard end == nil else { return }
        end = requested
        // In the countdown, closing the chrome ends it.
        if waiting == nil { chrome.close() }
        waiting?.resume()
        waiting = nil
    }

    private func tick() {
        let recorded = recorder.recordedTime
        let remaining = ScreenRecorder.maximumDuration - recorded
        chrome.update(recorded: recorded, remaining: remaining <= 30 ? remaining : nil)
        onTick(recorded)
    }
}

/// What a recording's thumbnail says under it.
enum RecordingNote {
    /// GitHub's upload limit a GIF is fitted to, as the user reads it.
    static let gifLimit = "\(GIFEncoder.byteBudget / 1_000_000) MB"

    static func text(fellBackToMP4: Bool, stoppedEarly: Error?, eventsSaved: Bool) -> String? {
        var notes: [String] = []
        if let stoppedEarly {
            notes.append("Stopped early: \(stoppedEarly.localizedDescription)")
        }
        if fellBackToMP4 { notes.append("Too long for a \(gifLimit) GIF — saved as MP4") }
        if !eventsSaved { notes.append("Shortcuts and clicks couldn't be saved") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

/// The first frame of a recording's primary, for its thumbnail.
enum RecordingPoster {
    static func firstFrame(of url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }
}
