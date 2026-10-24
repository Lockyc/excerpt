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
    /// Moves the pointer to the scroll point once, the first time a step is checked for, unless
    /// it is already there: the window under the pointer takes wheel events, and moving it
    /// every step would fight the user reaching for Done. A capture the user scrolls never
    /// moves it. A failed move shows as `.pointerMoved`.
    private lazy var placed =
        CGEvent(source: nil)?.location == point || CGWarpMouseCursorPosition(point) == .success

    /// Stamped on every wheel event Excerpt posts, so the user's own can be told apart.
    public nonisolated static let marker: Int64 = 0x4558_4350  // "EXCP"

    /// `point` (from `ScrollChromeLayout.scrollPoint`) and `hud` are in AppKit points.
    public init(region: ScrollRegion, point at: CGPoint, hud: CGRect) {
        point = region.quartz(CGRect(origin: at, size: .zero)).origin
        self.region = region.quartz(region.appKitFrame)
        self.hud = region.quartz(hud)
    }

    /// Whether Excerpt posted `event`.
    public nonisolated static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
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
            Self.scrollsPage(at: pointer, region: region, hud: hud) || hud.contains(pointer)
        else { return .pointerMoved }
        return nil
    }

    public var waits: Bool {
        guard let pointer = CGEvent(source: nil)?.location else { return false }
        return hud.contains(pointer)
    }

    public func scroll(points: Double) -> Bool {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -Int32(points.rounded()), wheel2: 0, wheel3: 0)
        else { return false }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
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
