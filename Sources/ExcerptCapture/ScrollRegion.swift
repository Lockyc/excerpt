import CoreGraphics
import ExcerptCore

/// The region a scrolling capture follows, in every space it is used in: pixels for the frames,
/// display-local points for the stream, AppKit points for the HUD and preview, and Quartz points
/// where scroll events are posted.
public struct ScrollRegion: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let scale: CGFloat
    /// In the display's pixels: the size of every frame.
    public let pixelRect: CGRect
    /// Display-local, top-left points: the stream's source rect.
    public let localPoints: CGRect
    /// AppKit global points.
    public let appKitFrame: CGRect
    /// The primary display's full frame height, which flips AppKit to Quartz.
    public let primaryHeight: CGFloat

    /// `displayFrame` is the display's AppKit frame; `pixelRect` a rect of its still.
    public init(
        displayID: CGDirectDisplayID, displayFrame: CGRect, scale: CGFloat, pixelRect: CGRect,
        primaryHeight: CGFloat
    ) {
        self.displayID = displayID
        self.scale = scale
        self.pixelRect = pixelRect
        self.primaryHeight = primaryHeight
        localPoints = DisplayGeometry.localPoints(forPixelRect: pixelRect, scale: scale)
        appKitFrame = DisplayGeometry.appKitRect(
            forLocalPoints: localPoints, displayFrame: displayFrame)
    }

    /// An AppKit rect in Quartz global points, where CGEvents are posted.
    public func quartz(_ rect: CGRect) -> CGRect {
        DisplayGeometry.quartzRect(fromAppKit: rect, primaryHeight: primaryHeight)
    }

    /// One auto-scroll step, in points.
    public var stepPoints: Double {
        ScrollSession.stepPoints(regionHeightPoints: Double(localPoints.height))
    }
}
