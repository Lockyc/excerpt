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

    /// A cursorless, best-resolution still of `width`×`height` points at `scale`.
    private static func still(width: CGFloat, height: CGFloat, scale: CGFloat)
        -> SCStreamConfiguration
    {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width * scale)
        configuration.height = Int(height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    /// A full-resolution still of every display, without excerpt's own windows or the Finder's
    /// desktop icons. Taken before the overlay appears: the frozen screen. The displays are
    /// captured at once, so each one added doesn't lengthen the wait for the overlay.
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
        let requests = content.displays.compactMap { display -> StillRequest? in
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID })
            else { return nil }
            let scale = screen.backingScaleFactor
            let configuration = Self.still(
                width: CGFloat(display.width), height: CGFloat(display.height), scale: scale)
            return StillRequest(
                displayID: display.displayID, frame: screen.frame, scale: scale,
                filter: SCContentFilter(display: display, excludingWindows: excluded),
                configuration: configuration)
        }
        return try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: request.filter, configuration: request.configuration)
                    return (index, image)
                }
            }
            var images: [Int: CGImage] = [:]
            for try await (index, image) in group { images[index] = image }
            return requests.enumerated().map { index, request in
                DisplayStill(
                    displayID: request.displayID, frame: request.frame, scale: request.scale,
                    image: images[index]!)
            }
        }
    }

    /// One display's still, as asked for on the main actor before the captures start.
    private struct StillRequest {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    /// Normal-layer, on-screen windows of other apps, frontmost first.
    public func windowsFrontToBack() async throws -> [CapturableWindow] {
        try await windowList().pickable
    }

    /// Every on-screen window front to back (CGWindowList gives the z-order; ScreenCaptureKit's
    /// list does not), and those of them a capture can pick: quick to list, so a selection can
    /// show the windows while `windowStills(of:)` is still taking their images.
    public func windowList() async throws -> WindowList {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let byID = Dictionary(
            content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let order =
            (CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
        let all = order.compactMap { info in
            (info[kCGWindowNumber as String] as? CGWindowID).flatMap { byID[$0] }
        }
        let pickable = all.compactMap { window -> CapturableWindow? in
            guard window.windowLayer == 0, window.owningApplication?.processID != ownPID,
                window.frame.width > 1
            else { return nil }
            return CapturableWindow(
                window: window,
                frame: DisplayGeometry.appKitRect(
                    fromQuartz: window.frame, primaryHeight: NSScreen.primaryHeight),
                title: window.title ?? window.owningApplication?.applicationName ?? "")
        }
        return WindowList(content: content, all: all, pickable: pickable)
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
        let configuration = Self.still(
            width: CGFloat(display.width), height: CGFloat(display.height), scale: scale)
        let filter = SCContentFilter(display: display, including: windows)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    /// Every window of `list` a capture can pick, each by itself as it shows now, frontmost
    /// first: the window stills, taken with the display stills so they keep hover states and
    /// the menus that activating Excerpt closes. A window that closes meanwhile is left out.
    public func windowStills(of list: WindowList) async -> [WindowStill] {
        let (content, all, pickable) = (list.content, list.all, list.pickable)
        let stacked = all.map {
            StackedWindow(
                id: $0.windowID, pid: $0.owningApplication?.processID ?? 0,
                layer: $0.windowLayer, frame: $0.frame)
        }
        let byID = Dictionary(
            all.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let requests = pickable.map { window in
            let target = stacked.first { $0.id == window.window.windowID }!
            let overlays = WindowStack.overlays(of: target, in: stacked)
            return request(
                for: window, overlays: overlays.compactMap { byID[$0.id] },
                reach: WindowStack.frame(of: target, with: overlays), displays: content.displays)
        }
        return await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: request.filter, configuration: request.configuration)
                    return (index, image)
                }
            }
            var images: [Int: CGImage] = [:]
            for await (index, image) in group { images[index] = image }
            return requests.enumerated().compactMap { index, request in
                images[index].map {
                    WindowStill(window: request.window, image: $0, scale: request.scale)
                }
            }
        }
    }

    /// One window's still, as asked for on the main actor before the captures start.
    private struct WindowRequest {
        let window: CapturableWindow
        let scale: CGFloat
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    /// The capture of `window` with its `overlays`, without its shadow (the backdrop frames it
    /// instead), at the scale of the display it lies on.
    ///
    /// A window that lies on one display is cut from that display with only itself and its
    /// overlays composited, over `reach` within that display: a desktop-independent filter
    /// renders a sheet's whole window tree — the parent with the sheet on it — shrunk into the
    /// sheet's size. A window spanning displays falls back to the desktop-independent filter,
    /// which no single display can hold, and so to the window alone.
    private func request(
        for window: CapturableWindow, overlays: [SCWindow], reach: CGRect, displays: [SCDisplay]
    ) -> WindowRequest {
        // The screen holding most of the window sets the scale.
        let scale =
            NSScreen.screens.max {
                $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area
            }?.backingScaleFactor ?? 2
        let frame = window.window.frame
        guard let display = displays.first(where: { $0.frame.contains(frame) }) else {
            let configuration = Self.still(width: frame.width, height: frame.height, scale: scale)
            configuration.ignoreShadowsSingleWindow = true
            return WindowRequest(
                window: window, scale: scale,
                filter: SCContentFilter(desktopIndependentWindow: window.window),
                configuration: configuration)
        }
        let area = reach.intersection(display.frame)
        let configuration = Self.still(width: area.width, height: area.height, scale: scale)
        configuration.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return WindowRequest(
            window: window, scale: scale,
            filter: SCContentFilter(display: display, including: [window.window] + overlays),
            configuration: configuration)
    }
}

/// The on-screen windows as `ScreenCapturer.windowList` found them.
public struct WindowList {
    let content: SCShareableContent
    /// Every on-screen window, front to back.
    let all: [SCWindow]
    /// The windows a capture can pick, frontmost first.
    public let pickable: [CapturableWindow]
}

/// A window as it showed when the capture started, with its app's menus and popovers over it.
public struct WindowStill {
    public let window: CapturableWindow
    public let image: CGImage
    public let scale: CGFloat
}

extension CGRect {
    /// Zero for a rect that is null, as a non-overlapping intersection is.
    fileprivate var area: CGFloat { isNull ? 0 : width * height }
}
