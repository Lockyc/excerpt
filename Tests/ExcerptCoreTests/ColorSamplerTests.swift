import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct ColorSamplerTests {
    static let ground = RGBA(r: 0x27, g: 0x2C, b: 0x35, a: 255)
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)

    static func buffer(
        _ width: Int, _ height: Int, fill: RGBA, paint: (inout PixelBuffer) -> Void = { _ in }
    ) -> PixelBuffer {
        var buffer = PixelBuffer(
            width: width, height: height,
            bytes: (0..<(width * height)).flatMap { _ in [fill.r, fill.g, fill.b, fill.a] })
        paint(&buffer)
        return buffer
    }

    static func set(_ buffer: inout PixelBuffer, _ x: Int, _ y: Int, _ c: RGBA) {
        let i = (y * buffer.width + x) * 4
        buffer.bytes[i] = c.r
        buffer.bytes[i + 1] = c.g
        buffer.bytes[i + 2] = c.b
        buffer.bytes[i + 3] = c.a
    }

    static func stroke(_ buffer: inout PixelBuffer, _ rect: CGRect, _ c: RGBA) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) { set(&buffer, x, y, c) }
        }
    }

    @Test func edgeColorOfACellIsItsGround() {
        // A 100x30 cell at (20,20) with white 1px gridlines around it, white text inside.
        let image = Self.buffer(160, 80, fill: Self.ground) { b in
            Self.stroke(&b, CGRect(x: 20, y: 20, width: 100, height: 1), Self.white)
            Self.stroke(&b, CGRect(x: 20, y: 49, width: 100, height: 1), Self.white)
            Self.stroke(&b, CGRect(x: 20, y: 20, width: 1, height: 30), Self.white)
            Self.stroke(&b, CGRect(x: 119, y: 20, width: 1, height: 30), Self.white)
            Self.stroke(&b, CGRect(x: 30, y: 30, width: 60, height: 8), Self.white)
        }
        let interior = CGRect(x: 21, y: 21, width: 98, height: 28).insetBy(dx: 2, dy: 2)
        #expect(ColorSampler.edgeColor(around: interior, in: image) == Self.ground)
    }

    @Test func antialiasedNeighboursCountTogether() {
        // Rect (5,5,10,10): top and bottom rows alternate two close greys (12 + 12 pixels);
        // the 20 side pixels are white. Merged, the greys outnumber white; split, white wins.
        let near = RGBA(r: 0x27 + 3, g: 0x2C - 2, b: 0x35, a: 255)
        let image = Self.buffer(20, 20, fill: Self.white) { b in
            for x in 4...15 {
                let c = x.isMultiple(of: 2) ? Self.ground : near
                Self.set(&b, x, 4, c)
                Self.set(&b, x, 15, c)
            }
        }
        let rect = CGRect(x: 5, y: 5, width: 10, height: 10)
        #expect(ColorSampler.edgeColor(around: rect, in: image, tolerance: 6) == Self.ground)
        #expect(ColorSampler.edgeColor(around: rect, in: image, tolerance: 0) == Self.white)
    }

    @Test func ringOutsideImageUsesOnlyInsidePixels() {
        let image = Self.buffer(10, 10, fill: Self.white) { b in
            Self.stroke(&b, CGRect(x: 0, y: 0, width: 10, height: 10), Self.white)
            Self.set(&b, 4, 2, Self.ground)
        }
        // Rect touching x=0: the left column is off-buffer and must not be counted or crash.
        let rect = CGRect(x: 0, y: 2, width: 4, height: 4)
        #expect(ColorSampler.edgeColor(around: rect, in: image) == Self.white)
    }

    @Test func ringWhollyOutsideIsNil() {
        let image = Self.buffer(10, 10, fill: Self.white)
        #expect(
            ColorSampler.edgeColor(around: CGRect(x: 50, y: 50, width: 5, height: 5), in: image)
                == nil)
        #expect(
            ColorSampler.edgeColor(around: CGRect(x: -30, y: -30, width: 5, height: 5), in: image)
                == nil)
    }

    @Test func pixelOutsideIsNil() {
        let image = Self.buffer(4, 4, fill: Self.ground)
        #expect(ColorSampler.pixel(at: CGPoint(x: 1.5, y: 2.5), in: image) == Self.ground)
        #expect(ColorSampler.pixel(at: CGPoint(x: -0.1, y: 1), in: image) == nil)
        #expect(ColorSampler.pixel(at: CGPoint(x: 4, y: 1), in: image) == nil)
        #expect(ColorSampler.pixel(at: CGPoint(x: 1, y: 4), in: image) == nil)
    }
}
