import AppKit
import Testing

@testable import ExcerptCapture

/// The overlay as drawn: the still, the tint around the selection and the outline, rendered off
/// screen from its layers.
@MainActor @Suite struct SelectionOverlayDrawingTests {
    /// 400 × 300 points at 1×: red over the top half, blue under it.
    private static let still: DisplayStill = {
        let context = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 150))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 150, width: 400, height: 150))
        return DisplayStill(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1,
            image: context.makeImage()!)
    }()

    /// The overlay settled on local points (100, 50)–(300, 250), rendered top-left first.
    private func rendered() -> NSBitmapImageRep {
        let window = OverlayWindow(
            displayID: 1, frame: Self.still.frame, finish: { _ in }, beginDrag: { _ in false },
            wholeDisplay: {})
        let previous = ScrollRegion(
            displayID: 1, displayFrame: Self.still.frame, scale: 1,
            pixelRect: CGRect(x: 100, y: 50, width: 200, height: 200), primaryHeight: 300)
        window.present(still: Self.still, mode: .scrollingArea(previous: previous))
        window.displayIfNeeded()
        CATransaction.flush()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        // CALayer renders bottom-left first; the bitmap is read top-left first.
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        window.contentView!.layer!.render(in: context)
        return bitmap
    }

    private func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let colour = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return (
            Int(colour.redComponent * 255), Int(colour.greenComponent * 255),
            Int(colour.blueComponent * 255)
        )
    }

    @Test func selectionShowsTheStillClearAndTheRestTinted() {
        let bitmap = rendered()
        #expect(rgb(bitmap, 200, 100) == (255, 0, 0))  // inside, top half
        #expect(rgb(bitmap, 200, 200) == (0, 0, 255))  // inside, bottom half
        let tinted = rgb(bitmap, 50, 100)  // outside, top half
        #expect(tinted.0 > 140 && tinted.0 < 190 && tinted.2 == 0)
        let tintedBlue = rgb(bitmap, 50, 200)
        #expect(tintedBlue.2 > 140 && tintedBlue.2 < 190 && tintedBlue.0 == 0)
    }

    /// The tint is plain bands around the highlight that cover the rest exactly once.
    @Test func tintBandsCoverAllButTheHighlight() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(OverlayView.tint(around: nil, in: bounds) == [bounds])
        #expect(
            OverlayView.tint(around: CGRect(x: 500, y: 0, width: 10, height: 10), in: bounds)
                == [bounds])
        let highlight = CGRect(x: 100, y: 50, width: 200, height: 200)
        let bands = OverlayView.tint(around: highlight, in: bounds)
        #expect(bands.count == 4)
        let covered: CGFloat = bands.map { $0.width * $0.height }.reduce(0, +)
        #expect(covered == CGFloat(400 * 300 - 200 * 200))
        for (i, a) in bands.enumerated() {
            #expect(!a.intersects(highlight))
            for b in bands[(i + 1)...] { #expect(!a.intersects(b)) }
        }
        // A highlight touching an edge leaves no empty band.
        #expect(
            OverlayView.tint(around: CGRect(x: 0, y: 0, width: 400, height: 100), in: bounds)
                == [CGRect(x: 0, y: 100, width: 400, height: 200)])
    }

    @Test func selectionIsOutlined() {
        let bitmap = rendered()
        // Just outside the left edge, above the start button.
        let edge = rgb(bitmap, 99, 80)
        #expect(edge.0 > 200 && edge.1 > 200 && edge.2 > 200)
        #expect(rgb(bitmap, 101, 80) == (255, 0, 0))
    }
}
