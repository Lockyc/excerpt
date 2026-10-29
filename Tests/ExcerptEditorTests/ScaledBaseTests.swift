import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

/// The canvas's tiled base gives the pixels drawing the base straight in would.
@Suite struct ScaledBaseTests {
    let image = Fixtures.sheet(width: 1200, height: 1600)

    /// A context like a flipped view's at `scale` device pixels per point.
    func context(width: Int, height: Int, scale: CGFloat) -> CGContext {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        return context
    }

    /// The image drawn whole, straight into the context.
    func direct(_ rect: CGRect, scale: CGFloat, quality: CGInterpolationQuality) -> PixelBuffer {
        let c = context(width: 1200, height: 1600, scale: scale)
        c.interpolationQuality = quality
        c.translateBy(x: 0, y: rect.maxY)
        c.scaleBy(x: 1, y: -1)
        c.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        return PixelBuffer(c.makeImage()!)
    }

    /// Draws through `base` into a fresh context.
    func tiled(
        _ base: ScaledBase, _ rect: CGRect, scale: CGFloat, quality: CGInterpolationQuality
    ) -> PixelBuffer {
        let c = context(width: 1200, height: 1600, scale: scale)
        let all = CGRect(x: 0, y: 0, width: 1200 / scale, height: 1600 / scale)
        base.draw(image, in: rect, visible: all, kept: all, quality: quality, into: c)
        return PixelBuffer(c.makeImage()!)
    }

    /// The first paint at a placement, drawn straight in, and the second, from tiles, both
    /// match the direct draw.
    @Test(arguments: [
        (
            CGRect(x: 10.3, y: 7.6, width: 480.5, height: 640.7), CGFloat(2),
            CGInterpolationQuality.high
        ),
        (CGRect(x: 24, y: 24, width: 300, height: 400), CGFloat(2), .high),
        (CGRect(x: 3.25, y: 5.75, width: 1200, height: 1600), CGFloat(1), .none),
    ])
    func tilesMatchTheDirectDraw(rect: CGRect, scale: CGFloat, quality: CGInterpolationQuality) {
        let base = ScaledBase()
        let expected = direct(rect, scale: scale, quality: quality)
        let first = tiled(base, rect, scale: scale, quality: quality)
        #expect(base.tilesDrawn == 0)
        #expect(first.fractionDiffering(from: expected, tolerance: 2) <= 0.0005)
        let second = tiled(base, rect, scale: scale, quality: quality)
        #expect(base.tilesDrawn > 1)  // the seams between tiles are in the comparison
        #expect(second.fractionDiffering(from: expected, tolerance: 2) <= 0.0005)
    }

    @Test func aRepaintReusesItsTiles() {
        let base = ScaledBase()
        let rect = CGRect(x: 10.3, y: 7.6, width: 480.5, height: 640.7)
        _ = tiled(base, rect, scale: 2, quality: .high)
        _ = tiled(base, rect, scale: 2, quality: .high)
        let drawn = base.tilesDrawn
        _ = tiled(base, rect, scale: 2, quality: .high)
        // Moved by whole device pixels, the tiles still hold, and still match.
        let moved = rect.offsetBy(dx: 3, dy: -1.5)
        let shown = tiled(base, moved, scale: 2, quality: .high)
        #expect(base.tilesDrawn == drawn)
        let expected = direct(moved, scale: 2, quality: .high)
        #expect(shown.fractionDiffering(from: expected, tolerance: 2) <= 0.0005)
        // Moved by part of one, they are drawn again.
        let shifted = rect.offsetBy(dx: 0.25, dy: 0)
        _ = tiled(base, shifted, scale: 2, quality: .high)
        _ = tiled(base, shifted, scale: 2, quality: .high)
        #expect(base.tilesDrawn > drawn)
    }

    @Test func onlyTilesNearWhatIsShownAreKept() {
        let base = ScaledBase()
        let c = context(width: 1200, height: 1600, scale: 2)
        // Three rows of 512-pixel tiles down, three across.
        let rect = CGRect(x: 0, y: 0, width: 600, height: 768)
        let top = CGRect(x: 0, y: 0, width: 600, height: 100)
        base.draw(image, in: rect, visible: top, kept: top, quality: .high, into: c)
        base.draw(image, in: rect, visible: top, kept: top, quality: .high, into: c)
        #expect(base.tilesDrawn == 3)
        let bottom = CGRect(x: 0, y: 668, width: 600, height: 100)
        base.draw(image, in: rect, visible: bottom, kept: bottom, quality: .high, into: c)
        base.draw(image, in: rect, visible: top, kept: top, quality: .high, into: c)
        #expect(base.tilesDrawn == 9)
    }
}
