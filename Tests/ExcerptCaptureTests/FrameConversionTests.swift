import ExcerptCore
import ScreenCaptureKit
import Testing

@testable import ExcerptCapture

@Suite struct FrameConversionTests {
    @Test func theFirstAndEveryNewFrameCarryAPictureAndStatusSamplesDoNot() {
        #expect(FrameConversion.carriesPicture(.started))
        #expect(FrameConversion.carriesPicture(.complete))
        for status in [SCFrameStatus.idle, .blank, .suspended, .stopped] {
            #expect(!FrameConversion.carriesPicture(status))
        }
    }

    @Test func bgraRowsWithPaddingBecomeRGBA() {
        // 2×2 pixels, rows padded to 12 bytes.
        let bgra: [UInt8] = [
            1, 2, 3, 255, 4, 5, 6, 255, 0, 0, 0, 0,
            7, 8, 9, 255, 10, 11, 12, 128, 0, 0, 0, 0,
        ]
        let buffer = bgra.withUnsafeBytes {
            FrameConversion.pixelBuffer(bgra: $0, width: 2, height: 2, bytesPerRow: 12)
        }
        #expect(buffer.bytes == [3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 128])
    }

    @Test func theStreamsColourSpaceIsTheBuffersOwn() {
        #expect(StreamFrameSource.colorSpaceName == PixelBuffer.colorSpace.name)
    }

    @Test func thePointerIsInsideTheRegionOnlyWithinItsBounds() {
        let centre = CGPoint(x: 500, y: 400)
        let size = CGSize(width: 200, height: 100)
        #expect(EventScroller.region(centre: centre, size: size, contains: centre))
        #expect(EventScroller.region(centre: centre, size: size, contains: CGPoint(x: 400, y: 350)))
        #expect(
            !EventScroller.region(centre: centre, size: size, contains: CGPoint(x: 399, y: 400)))
        #expect(
            !EventScroller.region(centre: centre, size: size, contains: CGPoint(x: 500, y: 451)))
    }
}
