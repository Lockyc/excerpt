import AppKit
import ExcerptCapture
import ExcerptCore

/// Runs one capture end to end: permission → frozen stills → selection → image → deliver.
/// Main-actor: the overlay, alerts and sound are AppKit, and a plain async method would run off
/// the main thread in Swift 5 mode.
@MainActor
final class CaptureCoordinator {
    private let preferences: Preferences
    private let capturer = ScreenCapturer()
    private let onDelivered: (URL, CGImage) -> Void
    private var running = false
    static let shutter = NSSound(
        contentsOfFile:
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    init(preferences: Preferences, onDelivered: @escaping (URL, CGImage) -> Void) {
        self.preferences = preferences
        self.onDelivered = onDelivered
    }

    func run(_ action: HotKeyAction) async {
        guard !running else { return }  // a second hotkey press mid-selection is ignored
        running = true
        defer { running = false }
        guard ensurePermission() else { return }
        do {
            let stills = try await capturer.stills()
            switch action {
            case .area:
                if case .area(let still, let rect) = await SelectionOverlay().run(
                    mode: .area, stills: stills),
                    let image = still.image.cropping(to: rect)
                {
                    deliver(image, scale: still.scale)
                }
            case .window:
                let windows = try await capturer.windowsFrontToBack()
                if case .window(let window) = await SelectionOverlay().run(
                    mode: .window(windows: windows), stills: stills)
                {
                    let scale = stills.first { $0.frame.intersects(window.frame) }?.scale ?? 2
                    var image = try await capturer.image(of: window, scale: scale)
                    if preferences.windowBackdrop {
                        // The padding is a user setting; compose traps on a negative one.
                        image = Backdrop.compose(
                            image, padding: max(0, Int(preferences.windowPaddingPoints * scale)),
                            color: preferences.backdropColor)
                    }
                    deliver(image, scale: scale)
                }
            case .fullscreen:
                let mouse = NSEvent.mouseLocation
                if let still = stills.first(where: { $0.frame.contains(mouse) }) ?? stills.first {
                    deliver(still.image, scale: still.scale)
                }
            }
        } catch {
            Alerts.show("Capture failed", error.localizedDescription)
        }
    }

    private func deliver(_ image: CGImage, scale: CGFloat) {
        let store = preferences.store
        do {
            let url = try store.saveCapture(image, scale: Double(scale), at: Date())
            Pasteboard.copyPNG(at: url)
            if preferences.playSound { Self.shutter?.play() }
            onDelivered(url, image)
        } catch {
            Alerts.libraryUnwritable(store.folder, error)
        }
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
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )!)
        }
        return false
    }
}
