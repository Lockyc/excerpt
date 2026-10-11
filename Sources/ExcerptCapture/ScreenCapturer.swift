import AppKit
import ScreenCaptureKit

public struct DisplayStill {
    public let displayID: CGDirectDisplayID
    /// The display's frame in AppKit global points.
    public let frame: CGRect
    public let scale: CGFloat
    public let image: CGImage
}

public struct CapturableWindow {
    public let window: SCWindow
    /// AppKit global points.
    public let frame: CGRect
    public let title: String
}

extension NSScreen {
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The primary display's height in points: the axis flip between AppKit and Quartz global
    /// coordinates.
    @MainActor public static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

/// Main-actor because it reads `NSScreen`; in Swift 5 mode a nonisolated async method would hop
/// off the main thread and crash on the first AppKit call.
@MainActor
public final class ScreenCapturer {
    public init() {}

    public nonisolated static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; returns whether access is granted now.
    @discardableResult
    public nonisolated static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// A full-resolution still of every display, without excerpt's own windows or the Finder's
    /// desktop icons. Taken before the overlay appears: the frozen screen.
    public func stills() async throws -> [DisplayStill] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let excluded = content.windows.filter { window in
            window.owningApplication?.processID == ownPID
                || (window.owningApplication?.bundleIdentifier == "com.apple.finder"
                    && window.windowLayer == iconLayer)
        }
        var stills: [DisplayStill] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID })
            else { continue }
            let scale = screen.backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            stills.append(
                DisplayStill(
                    displayID: display.displayID, frame: screen.frame, scale: scale, image: image))
        }
        return stills
    }

    /// Normal-layer, on-screen windows of other apps, frontmost first (CGWindowList gives the
    /// z-order; ScreenCaptureKit's list does not).
    public func windowsFrontToBack() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let byID = Dictionary(
            content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let order =
            (CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
        return order.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                let window = byID[id], window.windowLayer == 0,
                window.owningApplication?.processID != ownPID, window.frame.width > 1
            else { return nil }
            return CapturableWindow(
                window: window,
                frame: DisplayGeometry.appKitRect(
                    fromQuartz: window.frame, primaryHeight: NSScreen.primaryHeight),
                title: window.title ?? window.owningApplication?.applicationName ?? "")
        }
    }

    /// The desktop picture of display `displayID` as it shows now, at `scale`, dynamic and
    /// aerial wallpapers included: the windows at or below the desktop level (the window
    /// manager's per-display wallpaper and the backstop behind it), without the desktop icons or
    /// widgets above them. Nil when the display has none.
    public func wallpaper(displayID: CGDirectDisplayID, scale: CGFloat) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let desktopLayer = Int(CGWindowLevelForKey(.desktopWindow))
        let windows = content.windows.filter {
            $0.windowLayer <= desktopLayer && $0.frame.intersects(display.frame)
        }
        guard !windows.isEmpty else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let filter = SCContentFilter(display: display, including: windows)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    /// One window, by itself, without its shadow (the backdrop frames it instead).
    ///
    /// A window that lies on one display is cut from that display with only itself composited:
    /// a desktop-independent filter renders a sheet's whole window tree — the parent with the
    /// sheet on it — shrunk into the sheet's size. A window spanning displays falls back to the
    /// desktop-independent filter, which no single display can hold.
    public func image(of window: CapturableWindow, scale: CGFloat) async throws -> CGImage {
        let frame = window.window.frame
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(frame.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        if let display = content.displays.first(where: { $0.frame.contains(frame) }) {
            filter = SCContentFilter(display: display, including: [window.window])
            configuration.sourceRect = frame.offsetBy(
                dx: -display.frame.minX, dy: -display.frame.minY)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window.window)
            configuration.ignoreShadowsSingleWindow = true
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }
}
