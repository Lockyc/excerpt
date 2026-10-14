import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptExport

/// Runs one capture end to end: permission → frozen stills → selection → image → deliver.
/// Main-actor: the overlay, alerts and sound are AppKit, and a plain async method would run off
/// the main thread in Swift 5 mode.
@MainActor
final class CaptureCoordinator {
    private let preferences: Preferences
    private let capturer = ScreenCapturer()
    /// Held for the coordinator's life: a menu item's target is weak.
    private let selector = CaptureSelector()
    private let onDelivered: (URL, CGImage) -> Void
    private var running = false
    /// Whether this launch has shown the system's Accessibility prompt.
    private var askedForAccessibility = false
    /// How the scrolling capture in progress was asked to end: the first request wins.
    private var scrollEnd: ScrollEnd?
    /// The last scrolling capture's region, for the next to open on; held for this launch.
    private var lastScrollRegion: ScrollRegion?
    static let shutter = NSSound(
        contentsOfFile:
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    init(preferences: Preferences, onDelivered: @escaping (URL, CGImage) -> Void) {
        self.preferences = preferences
        self.onDelivered = onDelivered
    }

    func run(_ requested: HotKeyAction) async {
        guard !running else { return }  // a second hotkey press mid-capture is ignored
        running = true
        defer { running = false }
        guard ensurePermission() else { return }
        if requested == .scrolling && !scrollingMayStart() { return }
        // Up before the stills are taken, so a click made meanwhile lands on the overlay.
        let overlay = SelectionOverlay()
        defer { overlay.close() }
        if requested.selects { overlay.cover() }
        do {
            let stills = try await capturer.stills()
            var action = requested
            // The selector shows over the stills already taken, so the screen it opened over is
            // the one captured; Esc or a click outside discards them, as does a display added,
            // removed or moved while it was open.
            if action == .selector {
                let preferences = preferences
                guard let mode = selector.choose(binding: { preferences.binding(for: $0) })
                else { return }
                let current = NSScreen.screens.compactMap { screen in
                    screen.displayID.map { ($0, screen.frame) }
                }
                if DisplayGeometry.arrangementChanged(
                    from: stills.map { ($0.displayID, $0.frame) }, to: current)
                {
                    Toast.show(Alerts.displaysChanged)
                    return
                }
                if mode == .scrolling && !scrollingMayStart() { return }
                action = mode
                if action.selects { overlay.cover() }
            }
            switch action {
            case .area:
                if case .area(let still, let rect) = await overlay.run(
                    mode: .area, stills: stills)
                {
                    await deliver(try Self.crop(still, to: rect), scale: still.scale)
                }
            case .window:
                let windows = try await capturer.windowsFrontToBack()
                if case .window(let window) = await overlay.run(
                    mode: .window(windows: windows), stills: stills)
                {
                    let still = stills.first { $0.frame.intersects(window.frame) }
                    let scale = still?.scale ?? 2
                    var image = try await capturer.image(of: window, scale: scale)
                    if preferences.windowBackdrop {
                        var fill = Backdrop.Fill.color(preferences.backdropColor)
                        if preferences.backdropStyle == .wallpaper, let still,
                            let wallpaper = try? await capturer.wallpaper(
                                displayID: still.displayID, scale: scale)
                        {
                            fill = .image(wallpaper)
                        }
                        image = Backdrop.compose(
                            image, padding: Int(preferences.windowPaddingPoints * scale),
                            fill: fill)
                    }
                    await deliver(image, scale: scale)
                }
            case .fullscreen:
                let mouse = NSEvent.mouseLocation
                if let still = stills.first(where: { $0.frame.contains(mouse) }) ?? stills.first {
                    await deliver(still.image, scale: still.scale)
                }
            case .scrolling:
                switch await overlay.run(
                    mode: .scrollingArea(previous: lastScrollRegion), stills: stills)
                {
                case .area(let still, let rect):
                    try await captureScrolling(
                        still: still, pixelRect: rect, start: .auto, overlay: overlay)
                case .scrolledArea(let still, let rect):
                    try await captureScrolling(
                        still: still, pixelRect: rect, start: .manual, overlay: overlay)
                case .window, .cancelled:
                    break
                }
            case .text:
                if case .area(let still, let rect) = await overlay.run(
                    mode: .area, stills: stills)
                {
                    await copyText(of: try Self.crop(still, to: rect), scale: still.scale)
                }
            case .selector:
                return  // resolved to the mode picked above
            }
        } catch {
            Alerts.show("Capture failed", error.localizedDescription)
        }
    }

    /// A selection that can't be cut from its still.
    private struct CropFailed: LocalizedError {
        var errorDescription: String? { "The selection couldn't be cut from the screen." }
    }

    /// The selection `rect`, in pixels, cut from `still`.
    private static func crop(_ still: DisplayStill, to rect: CGRect) throws -> CGImage {
        guard let image = still.image.cropping(to: rect) else { throw CropFailed() }
        return image
    }

    /// Capture Text: reads the selection off the main thread and copies its text, with no file
    /// and no sound. A selection with no text leaves the clipboard as it was, and says so.
    private func copyText(of image: CGImage, scale: CGFloat) async {
        let reading = Toast.show("Reading text…", seconds: nil)
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try CaptureText.read(
                    image, scale: Double(scale), recognizer: VisionTextRecognizer())
            }
        }.value
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
    /// keeps `overlay` up until its first frame.
    private func captureScrolling(
        still: DisplayStill, pixelRect: CGRect, start: ScrollStart, overlay: SelectionOverlay
    ) async throws {
        defer { overlay.dismiss() }
        let region = ScrollRegion(
            displayID: still.displayID, displayFrame: still.frame, scale: still.scale,
            pixelRect: pixelRect, primaryHeight: NSScreen.primaryHeight)
        lastScrollRegion = region
        let source = StreamFrameSource()
        try await source.start(region: region)
        scrollEnd = nil
        let visible =
            NSScreen.screens.first { $0.displayID == region.displayID }?.visibleFrame
            ?? region.appKitFrame
        let hud = ScrollChromeLayout.hud(
            size: ScrollWindows.hudSize, region: region.appKitFrame, visible: visible)
        let capture = ScrollCapture(
            source: source, scroller: EventScroller(region: region, hud: hud),
            stepPoints: region.stepPoints, scale: Double(region.scale), start: start)
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
        capture.onChange = { [weak windows] in
            overlay.dismiss()
            windows?.update($0)
        }
        // The user's own wheel over the region hands scrolling to them; Excerpt's steps carry
        // EventScroller.marker.
        let quartzRegion = region.quartz(region.appKitFrame)
        let wheel = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak capture] event in
            guard let cg = event.cgEvent, !EventScroller.isOwn(cg),
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
        let outcome = await capture.run()
        NotificationCenter.default.removeObserver(observer)
        if let wheel { NSEvent.removeMonitor(wheel) }
        source.onFailure = nil
        windows.close()
        var stopFailure: Error?
        do {
            try await source.stop()
        } catch {
            stopFailure = error
        }
        var saved = false
        var stopped: Error?
        switch outcome {
        case .saved(let image):
            saved = await deliver(image.makeImage(), scale: region.scale)
            if case .stopped(let error) = scrollEnd { stopped = error }
        case .cancelled:
            break
        case .failed(let error, let partial):
            if let partial { saved = await deliver(partial.makeImage(), scale: region.scale) }
            stopped = error
        }
        scrollEnd = nil
        if let stopped { Alerts.scrollingStopped(stopped, savedPartial: saved) }
        if let stopFailure { Alerts.recordingNotStopped(stopFailure, saved: saved) }
    }

    private func endScrolling(_ end: ScrollEnd) {
        if scrollEnd == nil { scrollEnd = end }
    }

    /// Without Accessibility, asks how to go on before the stills are taken, or after a pick from
    /// the selector, so neither the alert nor the system prompt lands in a still. The system
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
            do {
                try Pasteboard.copyPNG(at: url)
            } catch {
                Alerts.clipboardFailed(url, error)
            }
            if preferences.playSound { Self.shutter?.play() }
            onDelivered(url, image)
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
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Self.open(.screenRecording) }
        return false
    }
}
