import ApplicationServices
import CoreGraphics
import ExcerptCore

/// Posts scroll-wheel events at the region's centre. Needs Accessibility access; without it the
/// events are dropped, so `blocker` is read before every step.
@MainActor
public final class EventScroller: Scroller {
    private let centre: CGPoint
    private let size: CGSize
    private let placed: Bool

    /// Moves the pointer to the region's centre once, here: the window under the pointer takes
    /// wheel events, and moving it every step would fight the user reaching for Done. A failed
    /// move shows as `.pointerMoved`.
    public init(region: ScrollRegion) {
        centre = region.quartzCentre
        size = region.localPoints.size
        placed = CGWarpMouseCursorPosition(region.quartzCentre) == .success
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
            Self.region(centre: centre, size: size, contains: pointer)
        else { return .pointerMoved }
        return nil
    }

    public func scroll(points: Double) -> Bool {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -Int32(points.rounded()), wheel2: 0, wheel3: 0)
        else { return false }
        event.location = centre
        event.post(tap: .cghidEventTap)
        return true
    }

    nonisolated static func region(centre: CGPoint, size: CGSize, contains point: CGPoint) -> Bool {
        abs(point.x - centre.x) <= size.width / 2 && abs(point.y - centre.y) <= size.height / 2
    }
}
