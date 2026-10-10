import CoreGraphics
import ExcerptCore

/// The region a scrolling capture follows, in every space it is used in: pixels for the frames,
/// display-local points for the stream, AppKit points for the HUD and preview, and the Quartz
/// point where scroll events are posted.
public struct ScrollRegion: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let scale: CGFloat
    /// In the display's pixels: the size of every frame.
    public let pixelRect: CGRect
    /// Display-local, top-left points: the stream's source rect.
    public let localPoints: CGRect
    /// AppKit global points.
    public let appKitFrame: CGRect
    /// The region's centre in Quartz global points.
    public let quartzCentre: CGPoint

    /// `displayFrame` is the display's AppKit frame; `pixelRect` a rect of its still;
    /// `primaryHeight` the primary display's full frame height, which flips AppKit to Quartz.
    public init(
        displayID: CGDirectDisplayID, displayFrame: CGRect, scale: CGFloat, pixelRect: CGRect,
        primaryHeight: CGFloat
    ) {
        self.displayID = displayID
        self.scale = scale
        self.pixelRect = pixelRect
        localPoints = DisplayGeometry.localPoints(forPixelRect: pixelRect, scale: scale)
        appKitFrame = DisplayGeometry.appKitRect(
            forLocalPoints: localPoints, displayFrame: displayFrame)
        quartzCentre = DisplayGeometry.quartzPoint(
            forLocalPoint: CGPoint(x: localPoints.midX, y: localPoints.midY),
            displayFrame: displayFrame, primaryHeight: primaryHeight)
    }

    /// One auto-scroll step, in points.
    public var stepPoints: Double {
        ScrollSession.stepPoints(regionHeightPoints: Double(localPoints.height))
    }
}
