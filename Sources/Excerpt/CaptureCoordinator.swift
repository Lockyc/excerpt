import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptExport
import ExcerptRecording
import os

/// Runs one capture end to end: permission → frozen stills → selection → image → deliver.
/// Main-actor: the overlay, alerts and sound are AppKit, and a plain async method would run off
/// the main thread in Swift 5 mode.
@MainActor
final class CaptureCoordinator {
    private let preferences: Preferences
    private let capturer = ScreenCapturer()
    private let onDelivered: (URL, CGImage) -> Void
    /// A recording's primary, its first frame, and the note its thumbnail shows.
    private let onRecorded: (URL, CGImage, String?) -> Void
    /// The recorded time as the menu bar shows it while recording; nil once it has ended.
    private let onRecordingTime: (String?) -> Void
    /// What runs, records and saves, and when a quit may answer.
    private var lifecycle = CaptureLifecycle<
        HotKeyAction, RecordingSession, CheckedContinuation<Void, Never>
    >(record: .record, selector: .selector)
    /// The app that was frontmost as this capture began, before any of Excerpt's windows.
    private var frontmostAtStart: NSRunningApplication?
    /// The area last recorded, for the next recording to open on; held for this launch.
    private var lastRecordRegion: ScrollRegion?
    /// Whether this launch has asked for Input Monitoring.
    private var askedForInputMonitoring = false
    /// The overlay waiting on the selection `lifecycle.selecting` is up for.
    private var selectingOverlay: SelectionOverlay?
    /// Whether this launch has shown the system's Accessibility prompt.
    private var askedForAccessibility = false
    /// How the scrolling capture in progress was asked to end: the first request wins.
    private var scrollEnd: ScrollEnd?
    /// The last scrolling capture's region, for the next to open on; held for this launch.
    private var lastScrollRegion: ScrollRegion?
    /// The window the last scrolling capture followed, for the next to open on; nil after an
    /// area.
    private var lastScrollWindow: CGWindowID?
    /// The area last picked from the mode bar, for the next to open on; held for this launch.
    private var lastModeBarRegion: ScrollRegion?
    /// Counts captures started; a text read copies only while no capture has started since it.
    private var started = 0
    /// When the capture under way began; `stage` logs each step's time since.
    private var startedAt = ContinuousClock.now
    static let shutter = NSSound(
        contentsOfFile:
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)
    static let textRead = NSSound(named: "Glass")

    init(
        preferences: Preferences, onDelivered: @escaping (URL, CGImage) -> Void,
        onRecorded: @escaping (URL, CGImage, String?) -> Void,
        onRecordingTime: @escaping (String?) -> Void
    ) {
        self.preferences = preferences
        self.onDelivered = onDelivered
        self.onRecorded = onRecorded
        self.onRecordingTime = onRecordingTime
    }

    /// Stops the recording in progress, if any, keeping it.
    func stopRecording() { lifecycle.recording?.stop() }

    /// Whether a capture is under way, selecting or delivering.
    var isRunning: Bool { lifecycle.running }

    /// Whether a recording is in progress or a stopped one is still saving.
    var isRecordingOrSaving: Bool { lifecycle.isRecordingOrSaving }

    /// Stops the recording in progress, keeping it, and returns once it and every other
    /// stopped recording are saved.
    func finishRecordings() async {
        await withCheckedContinuation { waiter in
            let quit = lifecycle.quitRequested(waiter)
            quit.stop?.stop()
            Self.resume(quit.replies)
        }
    }

    /// Logs that the capture under way reached `name`, with its milliseconds since it began.
    private func stage(_ name: String) {
        let ms = (ContinuousClock.now - startedAt) / .milliseconds(1)
        Log.capture.info("\(name, privacy: .public) at \(ms, format: .fixed(precision: 0)) ms")
    }

    private static func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters { waiter.resume() }
    }

    /// A hotkey for another mode, pressed while a selection is up, ends that selection and runs
    /// the new mode on the same stills; any other press mid-capture is ignored. The Record
    /// hotkey again is one of the ways to stop a recording.
    func run(_ requested: HotKeyAction) async {
        switch lifecycle.hotkey(requested) {
        case .stopRecording(let recording):
            recording.stop()
            return
        case .switchMode:
            selectingOverlay?.interrupt()
            return
        case .ignore:
            return
        case .start:
            break
        }
        defer { lifecycle.captureEnded() }
        // Read before an alert activates Excerpt.
        frontmostAtStart = NSWorkspace.shared.frontmostApplication
        started += 1
        startedAt = .now
        stage("\(requested) started")
        guard ensurePermission() else { return }
        if requested == .scrolling && !scrollingMayStart() { return }
        // Up before the stills are taken, so a click made meanwhile lands on the overlay.
        let overlay = SelectionOverlay()
        defer { overlay.close() }
        if requested.selects { overlay.cover() }
        // Every selecting mode can switch to Window, so each takes the window stills; the
        // overlay shows without waiting for them, and Window mode highlights from the list,
        // waiting only on the picked window's image once it is picked. The overlay takes the
        // keys once the frontmost app's windows are taken, before taking them changes them.
        let windowList = Task { requested.selects ? try await capturer.windowList() : nil }
        let windowStills = Task { () -> WindowStills? in
            guard let list = try await windowList.value else { return nil }
            let stills = capturer.windowStills(of: list)
            await stills.start()
            return stills
        }
        defer {
            windowList.cancel()
            Task { await (try? windowStills.value)??.cancel() }
        }
        let frontmostPID = frontmostAtStart?.processIdentifier
        overlay.takesKeysAfter = {
            await (try? windowStills.value)??.taken(ofApp: frontmostPID)
        }
        do {
            let stills = try await capturer.stills()
            stage("stills taken")
            var action = requested
            while true {
                lifecycle.switchedTo = nil
                try await capture(
                    action, stills: stills, windowList: windowList, windowStills: windowStills,
                    overlay: overlay)
                guard let next = lifecycle.switchedTo else { return }
                if next == .scrolling && !overlay.aside({ scrollingMayStart() }) { return }
                action = next
            }
        } catch {
            // The deferred close runs only once this catch returns, and the clear overlay sits
            // above the alert taking every click on every display.
            overlay.close()
            stage("failed")
            Alerts.captureFailed(error)
        }
    }

    /// Waits on `overlay` for a selection in `mode`, switchable by another mode's hotkey meanwhile.
    private func select(
        _ mode: SelectionMode, for action: HotKeyAction, overlay: SelectionOverlay,
        stills: [DisplayStill]
    ) async -> SelectionResult {
        lifecycle.selectionBegan(action)
        selectingOverlay = overlay
        defer {
            lifecycle.selectionEnded()
            selectingOverlay = nil
        }
        let result = await overlay.run(mode: mode, stills: stills)
        stage("selection ended")
        return result
    }

    /// Runs `action` on the stills already taken.
    private func capture(
        _ action: HotKeyAction, stills: [DisplayStill],
        windowList: Task<WindowList?, Error>, windowStills: Task<WindowStills?, Error>,
        overlay: SelectionOverlay
    ) async throws {
        switch action {
        case .area, .text:
            if case .area(let still, let rect) = await select(
                .area, for: action, overlay: overlay, stills: stills)
            {
                try await use(action, still: still, pixelRect: rect, overlay: overlay)
            }
        case .window:
            let windows = try await windowList.value?.pickable ?? []
            if case .window(let window) = await select(
                .window(windows: windows), for: action, overlay: overlay, stills: stills),
                let shot = try await windowStills.value?.still(of: window.window.windowID)
            {
                stage("window still in hand")
                // replayd takes stills one at a time: the backdrop's wallpaper still would
                // otherwise queue behind every window nobody picked.
                await (try? windowStills.value)??.cancel()
                let image = await windowBackdrop(shot.image, scale: shot.scale, frame: window.frame)
                await deliver(image, scale: shot.scale)
            }
        case .fullscreen:
            let mouse = NSEvent.mouseLocation
            if let still = stills.first(where: { $0.frame.contains(mouse) }) ?? stills.first {
                await deliver(still.image, scale: still.scale)
            }
        case .scrolling:
            let windows = try await capturer.windowsFrontToBack()
            // The last window reopens only while it is on a screen; else its last area does.
            let previousWindow = windows.first { $0.window.windowID == lastScrollWindow }
                .flatMap { window in
                    let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
                    return NSScreen.screens.contains { $0.frame.contains(centre) }
                        ? window.window.windowID : nil
                }
            switch await select(
                .scrollingArea(
                    previous: lastScrollRegion, previousWindow: previousWindow, windows: windows),
                for: action, overlay: overlay, stills: stills)
            {
            case .area(let still, let rect):
                try await use(action, still: still, pixelRect: rect, overlay: overlay)
            case .windowArea(let window, let still, let rect):
                try await captureScrolling(
                    still: still, pixelRect: rect, start: .auto, overlay: overlay, window: window)
            case .scrolledArea(let still, let rect, let window):
                try await captureScrolling(
                    still: still, pixelRect: rect, start: .manual, overlay: overlay,
                    window: window)
            default:
                break
            }
        case .record:
            guard !promptedForInputMonitoring(overlay: overlay) else { return }
            let windows = try await capturer.windowsFrontToBack()
            switch await select(
                .recordingArea(previous: lastRecordRegion, windows: windows), for: action,
                overlay: overlay, stills: stills)
            {
            case .area(let still, let rect):
                await record(still: still, pixelRect: rect, window: nil, overlay: overlay)
            case .windowArea(let window, let still, let rect):
                await record(still: still, pixelRect: rect, window: window, overlay: overlay)
            default:
                break
            }
        case .selector:
            let choices = HotKeyAction.modes.map { mode in
                ModeChoice(
                    id: mode.id, title: mode.modeName, symbol: mode.symbol,
                    shortcut: preferences.binding(for: mode)?.display, usesArea: mode.usesArea)
            }
            switch await select(
                .modeBar(previous: lastModeBarRegion, choices: choices), for: action,
                overlay: overlay, stills: stills)
            {
            case .chosenArea(let id, let still, let rect):
                lastModeBarRegion = ScrollRegion(
                    displayID: still.displayID, displayFrame: still.frame, scale: still.scale,
                    pixelRect: rect, primaryHeight: NSScreen.primaryHeight)
                if let mode = HotKeyAction(rawValue: id), mode != .scrolling || scrollingMayStart()
                {
                    try await use(mode, still: still, pixelRect: rect, overlay: overlay)
                }
            case .scrolledArea(let still, let rect, _):
                lastModeBarRegion = ScrollRegion(
                    displayID: still.displayID, displayFrame: still.frame, scale: still.scale,
                    pixelRect: rect, primaryHeight: NSScreen.primaryHeight)
                try await captureScrolling(
                    still: still, pixelRect: rect, start: .manual, overlay: overlay, window: nil)
            case .chosen(let id):
                lifecycle.switchedTo = HotKeyAction(rawValue: id)
            default:
                break
            }
        case .recent:
            // The app opens the panel itself; the coordinator never receives it.
            break
        }
    }

    /// Runs an area mode on the area already selected: Area saves it, Text copies its text,
    /// Scrolling starts following it, Record records it.
    private func use(
        _ mode: HotKeyAction, still: DisplayStill, pixelRect rect: CGRect,
        overlay: SelectionOverlay
    ) async throws {
        switch mode {
        case .area: await deliver(try Self.crop(still, to: rect), scale: still.scale)
        case .text:
            let image = try Self.crop(still, to: rect)
            Task { await copyText(of: image, scale: still.scale) }
        case .scrolling:
            try await captureScrolling(
                still: still, pixelRect: rect, start: .auto, overlay: overlay, window: nil)
        case .record:
            guard !promptedForInputMonitoring(overlay: overlay) else { return }
            await record(still: still, pixelRect: rect, window: nil, overlay: overlay)
        case .window, .fullscreen, .selector, .recent: break
        }
    }

    /// Records the selected area until it is stopped or discarded, then saves, copies and shows
    /// it, the save outliving this capture. With `window`, the window clicked to select it, only that app's shortcuts are
    /// logged; an area or display recording logs them from any app.
    private func record(
        still: DisplayStill, pixelRect rect: CGRect, window: CapturableWindow?,
        overlay: SelectionOverlay
    ) async {
        overlay.dismiss()
        let region = ScrollRegion(
            displayID: still.displayID, displayFrame: still.frame, scale: still.scale,
            pixelRect: rect, primaryHeight: NSScreen.primaryHeight)
        lastRecordRegion = region
        let store = preferences.store
        let paths: RecordingPaths
        do {
            paths = try store.reserveRecording(at: Date())
        } catch {
            Alerts.libraryUnwritable(store.folder, error)
            return
        }
        let windowPID = window?.window.owningApplication?.processID
        let session = RecordingSession(
            region: region, paths: paths, frontmostPID: windowPID,
            demonstrated: windowPID.flatMap(NSRunningApplication.init(processIdentifier:))
                ?? frontmostAtStart,
            ownHotKeys: HotKeyAction.allCases.compactMap { preferences.binding(for: $0) })
        session.onTick = { [weak self] in
            self?.onRecordingTime(RecordingChrome.timeText(recorded: $0, remaining: nil))
        }
        lifecycle.recordingStarted(session)
        let outcome = await session.run()
        let kept: Bool
        if case .saved = outcome { kept = true } else { kept = false }
        let ended = lifecycle.recordingEnded(kept: kept)
        // After the outcome is handled.
        defer { Self.resume(ended.replies) }
        onRecordingTime(nil)
        switch outcome {
        case .discarded:
            break
        case .failed(RecordingError.empty):
            Toast.show("Nothing was recorded")
        case .failed(let error):
            // A master that was written but can't be read back is still in the library.
            let kept =
                FileManager.default.fileExists(atPath: paths.master.path)
                ? " The recording is kept as \(paths.master.lastPathComponent)." : ""
            Alerts.show(
                "Recording failed", Alerts.sentence(error.localizedDescription) + kept)
        case .saved(let master, let stoppedEarly, let eventsSaved):
            // Its own task, so the hotkeys work again while it renders: this capture ends now.
            guard let id = ended.save else { break }
            Task {
                await deliverRecording(
                    master, paths: paths, stoppedEarly: stoppedEarly, eventsSaved: eventsSaved)
                Self.resume(lifecycle.saveEnded(id))
            }
        }
    }

    /// Saves the master's first edit document with `RecordingSave` and shows the thumbnail,
    /// saying when it ended early, fell back to MP4 or lost its shortcuts and clicks. No
    /// shutter: the recording's own end is the cue.
    private func deliverRecording(
        _ master: RecordingMaster, paths: RecordingPaths, stoppedEarly: Error?, eventsSaved: Bool
    ) async {
        let edits = RecordingEdits.fresh(
            duration: master.duration, format: preferences.recordingFormat)
        let saving = Toast.show("Saving the recording…", seconds: nil)
        let saved = await RecordingSave.run(master, edits: edits, paths: paths)
        Toast.dismiss(saving)
        guard let (result, copied) = saved else { return }
        let note = RecordingNote.text(
            fellBackToMP4: result.fellBackToMP4, stoppedEarly: stoppedEarly,
            eventsSaved: eventsSaved)
        guard let poster = await RecordingPoster.firstFrame(of: result.url) else {
            // No frame to show: the note still reaches the user.
            Toast.show(
                [copied ? "Recording saved and copied" : "Recording saved", note].compactMap { $0 }
                    .joined(separator: " · "))
            return
        }
        onRecorded(result.url, poster, note)
    }

    /// The one place a recording asks for Input Monitoring, at the start of every path into
    /// Record (its hotkey, a switch to it, the mode bar's Record). While the user has neither
    /// granted nor denied it, the first recording of a launch takes the overlay down, shows the
    /// system's prompt and ends there, so the prompt never lands in a recording; the next
    /// Record records. Denied, or asked already this launch, a recording logs clicks only.
    /// True when it prompted, so the run ends.
    private func promptedForInputMonitoring(overlay: SelectionOverlay) -> Bool {
        guard !askedForInputMonitoring, InputMonitoring.isUndecided() else { return false }
        askedForInputMonitoring = true
        overlay.dismiss()
        InputMonitoring.request()
        return true
    }

    /// A selection that can't be cut from its still.
    private struct CropFailed: LocalizedError {
        var errorDescription: String? { "The selection couldn't be cut from the screen." }
    }

    /// The area `a` and `b` share.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    /// The selection `rect`, in pixels, cut from `still`.
    private static func crop(_ still: DisplayStill, to rect: CGRect) throws -> CGImage {
        guard let image = still.image.cropping(to: rect) else { throw CropFailed() }
        return image
    }

    /// Capture Text: reads the selection off the main thread and copies its text, with no file,
    /// chiming when the read is done. A selection with no text leaves the clipboard as it was,
    /// and says so. The read runs after its capture has ended, since it can take a minute while
    /// macOS recompiles Vision's models, so the next capture never waits on it; once one
    /// starts, this read copies nothing and says nothing.
    private func copyText(of image: CGImage, scale: CGFloat) async {
        let capture = started
        let reading = Toast.show("Reading text…", seconds: nil)
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try CaptureText.read(
                    image, scale: Double(scale), recognizer: VisionTextRecognizer())
            }
        }.value
        guard started == capture else {
            Toast.dismiss(reading)
            return
        }
        if case .success = result, preferences.playSound { Self.textRead?.play() }
        switch result {
        case .success(let text) where text.isEmpty:
            Toast.show("No text found · the clipboard is unchanged")
        case .success(let text):
            do {
                try Pasteboard.copyText(String(text.dropLast()))
                let lines = text.split(separator: "\n").count
                Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text")
            } catch {
                Toast.dismiss(reading)
                Alerts.textCopyFailed(error)
            }
        case .failure(let error):
            Toast.dismiss(reading)
            Alerts.textUnreadable(error)
        }
    }

    /// How a scrolling capture was asked to end. The user's Done or Cancel needs no word after;
    /// a failed stream or a display change does, even when what was stitched saved cleanly.
    private enum ScrollEnd {
        case user
        case stopped(Error)
    }

    /// Streams the selected region while the page scrolls under it, stitching as it goes, with
    /// the HUD over it and the live preview beside it. Saves like any capture. The region is
    /// kept for the next scrolling capture to open on. A capture the user started by scrolling
    /// keeps `overlay` up until its first frame. With `window`, wholly on the still's display,
    /// it follows that window: raised, auto-scrolled at its centre, streamed alone, its shape fixed as chrome,
    /// ended by its moving, resizing or closing, and saved on the window backdrop. A window that isn't
    /// wholly on that display is captured as the area it covers.
    private func captureScrolling(
        still: DisplayStill, pixelRect: CGRect, start: ScrollStart, overlay: SelectionOverlay,
        window picked: CapturableWindow?
    ) async throws {
        defer { overlay.dismiss() }
        let window = picked.flatMap { picked in
            ScrollRegion.followsWindow(windowFrame: picked.frame, displayFrame: still.frame)
                ? picked : nil
        }
        let region =
            window.flatMap {
                ScrollRegion(window: $0, still: still, primaryHeight: NSScreen.primaryHeight)
            }
            ?? ScrollRegion(
                displayID: still.displayID, displayFrame: still.frame, scale: still.scale,
                pixelRect: pixelRect, primaryHeight: NSScreen.primaryHeight)
        lastScrollRegion = region
        lastScrollWindow = window?.window.windowID
        if let window { Self.bringToFront(window) }
        let source = StreamFrameSource()
        scrollEnd = nil
        let visible =
            NSScreen.screens.first { $0.displayID == region.displayID }?.visibleFrame
            ?? region.appKitFrame
        // A followed window's auto-scroll lands at its centre: the pointer that picked it
        // usually sits on its title bar, which doesn't scroll.
        let frame = region.appKitFrame
        let point = ScrollChromeLayout.scrollPoint(
            pointer: window != nil && start == .auto
                ? CGPoint(x: frame.midX, y: frame.midY) : NSEvent.mouseLocation,
            region: frame)
        let hud = ScrollChromeLayout.hud(
            size: ScrollChromeLayout.hudSize, beside: point, visible: visible)
        let capture = ScrollCapture(
            source: source, scroller: EventScroller(region: region, point: point, hud: hud),
            stepPoints: region.stepPoints, scale: Double(region.scale), start: start,
            chrome: window == nil ? { _ in .none } : { ScrollChrome.window(shapeOf: $0) })
        let windows = ScrollWindows(
            region: region.appKitFrame, hud: hud, visible: visible,
            onDone: { [weak self, weak capture] in
                self?.endScrolling(.user)
                capture?.finish()
            },
            onCancel: { [weak self, weak capture] in
                self?.endScrolling(.user)
                capture?.cancel()
            },
            onOpenAccessibility: { Self.open(.accessibility) })
        // `start` needs a window of Excerpt's open: the HUD and preview.
        do {
            if let window {
                try await source.start(window: window, region: region)
            } else {
                try await source.start(region: region)
            }
        } catch {
            overlay.dismiss()
            await windows.explain(.couldNotStart(error))
            windows.close()
            return
        }
        capture.onChange = { [weak windows] in
            overlay.dismiss()
            windows?.update($0)
        }
        // The user's own wheel over the region hands scrolling to them; Excerpt's steps carry
        // EventScroller.marker. Fingers resting on the trackpad send wheel events that move
        // nothing; those aren't scrolling.
        let quartzRegion = region.quartz(region.appKitFrame)
        let wheel = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak capture] event in
            guard event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0,
                let cg = event.cgEvent, !EventScroller.isOwn(cg),
                quartzRegion.contains(cg.location)
            else { return }
            MainActor.assumeIsolated { capture?.userScrolled() }
        }
        // A failed stream or a display change ends the capture with what is stitched so far,
        // including while it is halted and reading no frames.
        source.onFailure = { [weak self, weak capture] error in
            self?.endScrolling(.stopped(error))
            capture?.finish()
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self, weak capture] _ in
            MainActor.assumeIsolated {
                self?.endScrolling(.stopped(ScrollCaptureError.displayChanged))
                capture?.finish()
            }
        }
        // The window moving, resizing or going away ends the capture as a display change does.
        let watch = window.map { window in
            let id = window.window.windowID
            let bounds = Self.bounds(ofWindow: id)
            return Task { [weak self, weak capture] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.windowPoll)
                    guard !Task.isCancelled else { return }
                    if bounds == nil || Self.bounds(ofWindow: id) != bounds {
                        self?.endScrolling(.stopped(ScrollCaptureError.windowChanged))
                        capture?.finish()
                        return
                    }
                }
            }
        }
        let outcome = await capture.run()
        watch?.cancel()
        NotificationCenter.default.removeObserver(observer)
        if let wheel { NSEvent.removeMonitor(wheel) }
        source.onFailure = nil
        var stopFailure: Error?
        do {
            try await source.stop()
        } catch {
            stopFailure = error
        }
        var stopped: Error?
        var image: PixelBuffer?
        switch outcome {
        case .saved(let stitch):
            image = stitch
            if case .stopped(let error) = scrollEnd { stopped = error }
        case .cancelled:
            break
        case .failed(let error, let partial):
            image = partial
            stopped = error
        }
        scrollEnd = nil
        // The HUD stays up only to say why the capture ended early.
        if stopped == nil && stopFailure == nil { windows.close() }
        var saved = false
        if let image {
            var cgImage = image.makeImage()
            if let window {
                cgImage = await windowBackdrop(cgImage, scale: region.scale, frame: window.frame)
            }
            saved = await deliver(cgImage, scale: region.scale)
        }
        if let stopped { await windows.explain(.stopped(stopped, savedPartial: saved)) }
        if let stopFailure {
            await windows.explain(.recordingNotStopped(stopFailure, saved: saved))
        }
        windows.close()
    }

    private func endScrolling(_ end: ScrollEnd) {
        if scrollEnd == nil { scrollEnd = end }
    }

    /// How often a followed window's bounds are read again.
    static let windowPoll: Duration = .milliseconds(250)

    /// Window `id`'s bounds in Quartz points; nil once it is gone or off screen.
    private static func bounds(ofWindow id: CGWindowID) -> CGRect? {
        guard
            let info =
                (CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
                as? [[CFString: Any]])?.first,
            info[kCGWindowIsOnscreen] as? Bool == true,
            let bounds = info[kCGWindowBounds] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// With Accessibility, raises `window` over the others so the scroll events posted on it
    /// reach it, without activating its app: Excerpt stays active, so the HUD keeps Return and
    /// Esc. The window is the frontmost of its app's whose frame is within a point of
    /// `SCWindow.frame` on every edge, since the two APIs may round it differently.
    private static func bringToFront(_ window: CapturableWindow) {
        guard let pid = window.window.owningApplication?.processID, EventScroller.isTrusted
        else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let axWindows = value as? [AXUIElement]
        else { return }
        let frame = window.window.frame
        let match = axWindows.first { axWindow in
            var position = CGPoint.zero
            var size = CGSize.zero
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                AXUIElementCopyAttributeValue(
                    axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
                let positionValue, let sizeValue,
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            else { return false }
            let found = CGRect(origin: position, size: size)
            return abs(found.minX - frame.minX) <= 1 && abs(found.minY - frame.minY) <= 1
                && abs(found.maxX - frame.maxX) <= 1 && abs(found.maxY - frame.maxY) <= 1
        }
        if let match { AXUIElementPerformAction(match, kAXRaiseAction as CFString) }
    }

    /// `image` of a window on the window backdrop when that setting is on, its fill the
    /// wallpaper of the display holding most of `frame` (AppKit points) or the backdrop colour.
    private func windowBackdrop(_ image: CGImage, scale: CGFloat, frame: CGRect) async -> CGImage {
        guard preferences.windowBackdrop else { return image }
        var fill = Backdrop.Fill.color(preferences.backdropColor)
        let screen = NSScreen.screens.filter { $0.frame.intersects(frame) }.max {
            Self.overlap($0.frame, frame) < Self.overlap($1.frame, frame)
        }
        if preferences.backdropStyle == .wallpaper, let displayID = screen?.displayID {
            do {
                if let wallpaper = try await capturer.wallpaper(displayID: displayID, scale: scale)
                {
                    fill = .image(wallpaper)
                }
            } catch {
                Log.capture.error(
                    "wallpaper failed, backdrop colour used: \(error.localizedDescription, privacy: .public)"
                )
            }
            stage("wallpaper fetched")
        }
        return Backdrop.compose(
            image, padding: Int(preferences.windowPaddingPoints * scale), fill: fill)
    }

    /// Without Accessibility, asks how to go on before the stills are taken, or once the overlay
    /// is out of the way, so neither the alert nor the system prompt lands in a still. The system
    /// prompt is requested once per launch; after an earlier denial macOS may not show it again,
    /// so the alert always does. True when the capture should start: with access, or with the
    /// user scrolling.
    private func scrollingMayStart() -> Bool {
        guard !EventScroller.isTrusted else { return true }
        if !askedForAccessibility {
            askedForAccessibility = true
            if EventScroller.requestAccess() { return true }
        }
        switch Alerts.accessibilityNeeded() {
        case .openSettings:
            Self.open(.accessibility)
            return false
        case .scrollYourself: return true
        case .cancel: return false
        }
    }

    /// Saves to the library, copies, plays the shutter and shows the thumbnail. False when the
    /// capture could not be saved; its own alert has said why. The PNG is encoded and written
    /// off the main thread: a full-screen capture takes a quarter of a second to encode.
    @discardableResult
    private func deliver(_ image: CGImage, scale: CGFloat) async -> Bool {
        let store = preferences.store
        let date = Date()
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try store.saveCapture(image, scale: Double(scale), at: date)
            }.value
            stage("saved")
            do {
                try Pasteboard.copyPNG(at: url)
            } catch {
                Alerts.clipboardFailed(url, error)
            }
            if preferences.playSound { Self.shutter?.play() }
            onDelivered(url, image)
            stage("thumbnail shown")
            return true
        } catch let error as PNGError {
            Alerts.encodeFailed(error)
        } catch {
            Alerts.libraryUnwritable(store.folder, error)
        }
        return false
    }

    /// The Privacy & Security panes a capture can need.
    enum PrivacyPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func open(_ pane: PrivacyPane) {
        NSWorkspace.shared.open(
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
            )!)
    }

    /// Screen Recording must be granted before any capture; without it ScreenCaptureKit returns
    /// only the wallpaper, which would be saved as if it were a real capture.
    private func ensurePermission() -> Bool {
        if ScreenCapturer.hasPermission() || ScreenCapturer.requestPermission() { return true }
        let alert = NSAlert()
        alert.messageText = "Excerpt needs Screen Recording access"
        alert.informativeText =
            "Turn on Excerpt under Privacy & Security → Screen & System Audio Recording, then capture again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { Self.open(.screenRecording) }
        return false
    }
}
