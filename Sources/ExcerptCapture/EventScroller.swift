import ApplicationServices
import CoreGraphics
import ExcerptCore

/// Posts scroll-wheel events at the region's scroll point, clear of the HUD. Needs
/// Accessibility access; without it the events are dropped, so `blocker` is read before every
/// step.
@MainActor
public final class EventScroller: Scroller {
    private let point: CGPoint
    private let region: CGRect
    private let hud: CGRect
    private let placed: Bool

    /// Moves the pointer to the scroll point once, here: the window under the pointer takes
    /// wheel events, and moving it every step would fight the user reaching for Done. A failed
    /// move shows as `.pointerMoved`. `hud` is the HUD's AppKit frame.
    public init(region: ScrollRegion, hud: CGRect) {
        let at = ScrollChromeLayout.scrollPoint(region: region.appKitFrame, hud: hud)
        point = region.quartz(CGRect(origin: at, size: .zero)).origin
        self.region = region.quartz(region.appKitFrame)
        self.hud = region.quartz(hud)
        placed = CGWarpMouseCursorPosition(point) == .success
    }

    public nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt when access isn't granted; returns whether it is.
    @discardableResult
    public nonisolated static func requestAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    public var blocker: ManualReason? {
        guard Self.isTrusted else { return .accessibility }
        guard placed, let pointer = CGEvent(source: nil)?.location,
            Self.scrollsPage(at: pointer, region: region, hud: hud)
        else { return .pointerMoved }
        return nil
    }

    public func scroll(points: Double) -> Bool {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -Int32(points.rounded()), wheel2: 0, wheel3: 0)
        else { return false }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Whether a wheel event with the pointer at `pointer` reaches the page: over the region,
    /// edges included, and not over the HUD, which would take it.
    nonisolated static func scrollsPage(at pointer: CGPoint, region: CGRect, hud: CGRect) -> Bool {
        pointer.x >= region.minX && pointer.x <= region.maxX && pointer.y >= region.minY
            && pointer.y <= region.maxY && !hud.contains(pointer)
    }
}
