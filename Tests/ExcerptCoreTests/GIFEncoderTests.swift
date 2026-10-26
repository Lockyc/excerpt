import ExcerptTestSupport
import Foundation
import ImageIO
import Testing

@testable import ExcerptCore

@Suite struct GIFEncoderTests {
    /// Flat blocks of a small set of colours, shifted by `phase`: screen-like content.
    static func blocks(width: Int, height: Int, phase: Int) -> PixelBuffer {
        ScrollFixtures.paint(width: width, height: height) { x, y in
            let n = UInt8(((x + phase) / 8 + y / 6 * 5) % 12)
            return RGBA(r: n &* 20, g: 255 &- n &* 13, b: (n % 3) &* 90, a: 255)
        }
    }

    static func encode(_ frames: [(PixelBuffer, Int)]) -> Data {
        var encoder = GIFEncoder(width: frames[0].0.width, height: frames[0].0.height)
        for (frame, delay) in frames { encoder.add(frame, delay: delay) }
        return encoder.finish()
    }

    static func source(_ data: Data) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithData(data as CFData, nil))
    }

    static func frame(_ source: CGImageSource, _ index: Int) throws -> PixelBuffer {
        PixelBuffer(try #require(CGImageSourceCreateImageAtIndex(source, index, nil)))
    }

    /// The frame's delay in centiseconds, unclamped.
    static func delay(_ source: CGImageSource, _ index: Int) throws -> Int {
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let seconds = try #require(
            (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime])
                as? Double)
        return Int((seconds * 100).rounded())
    }

    @Test func flatColourFramesDecodeExactly() throws {
        var second = Self.blocks(width: 120, height: 80, phase: 0)
        for y in 30..<50 {
            for x in 40..<70 {
                let i = (y * 120 + x) * 4
                second.bytes.replaceSubrange(i..<i + 4, with: [250, 10, 200, 255])
            }
        }
        let frames = [
            Self.blocks(width: 120, height: 80, phase: 0), second,
            Self.blocks(width: 120, height: 80, phase: 3),
        ]
        let source = try Self.source(Self.encode(frames.map { ($0, 7) }))
        #expect(CGImageSourceGetCount(source) == 3)
        for (index, expected) in frames.enumerated() {
            #expect(try Self.frame(source, index) == expected)
            #expect(try Self.delay(source, index) == 7)
        }
    }

    @Test func staticFramesMergeAndSplitLongDelays() throws {
        let still = Self.blocks(width: 40, height: 30, phase: 0)
        let merged = try Self.source(Self.encode(Array(repeating: (still, 10), count: 4)))
        #expect(CGImageSourceGetCount(merged) == 1)
        #expect(try Self.delay(merged, 0) == 40)

        let long = try Self.source(Self.encode(Array(repeating: (still, 10_000), count: 7)))
        let count = CGImageSourceGetCount(long)
        #expect(count > 1)
        let delays = try (0..<count).map { try Self.delay(long, $0) }
        #expect(delays.reduce(0, +) == 70_000)
        #expect(delays.allSatisfy { $0 <= 65_535 })
        for index in 0..<count { #expect(try Self.frame(long, index) == still) }
    }

    @Test func onlyTheChangedRectangleIsStored() throws {
        let first = ScrollFixtures.page(width: 800, height: 600)
        var second = first
        for y in 300..<320 {
            for x in 400..<420 {
                let i = (y * 800 + x) * 4
                second.bytes.replaceSubrange(i..<i + 4, with: [200, 0, 0, 255])
            }
        }
        var encoder = GIFEncoder(width: 800, height: 600)
        encoder.add(first, delay: 10)
        let header = encoder.byteCount
        encoder.add(second, delay: 10)
        let afterFirst = encoder.byteCount
        let data = encoder.finish()
        let firstBytes = afterFirst - header
        let secondBytes = data.count - afterFirst
        #expect(firstBytes > 0)
        #expect(Double(secondBytes) < Double(firstBytes) * 0.05)
        let source = try Self.source(data)
        #expect(try Self.frame(source, 1) == second)
    }

    @Test func moreThan255ColoursStayWithinQuantiserError() throws {
        let gradient = ScrollFixtures.paint(width: 256, height: 256) { x, y in
            RGBA(r: UInt8(x), g: UInt8(y), b: UInt8(255 - x / 2), a: 255)
        }
        let decoded = try Self.frame(try Self.source(Self.encode([(gradient, 10)])), 0)
        var worst = 0
        for (a, b) in zip(decoded.bytes, gradient.bytes) {
            worst = max(worst, abs(Int(a) - Int(b)))
        }
        #expect(worst <= 16)
    }

    @Test func lossyFramesCompositeWithinQuantiserErrorAndRepeatsMerge() throws {
        let gradient = ScrollFixtures.paint(width: 128, height: 128) { x, y in
            RGBA(r: UInt8(x * 2), g: UInt8(y * 2), b: UInt8(255 - x), a: 255)
        }
        var changed = gradient
        for y in 40..<90 {
            for x in 30..<100 {
                let i = (y * 128 + x) * 4
                changed.bytes.replaceSubrange(
                    i..<i + 4, with: [UInt8(255 - y * 2), UInt8(x * 2), UInt8(y), 255])
            }
        }
        let inputs = [gradient, changed, changed]
        let source = try Self.source(Self.encode(inputs.map { ($0, 10) }))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(try Self.delay(source, 1) == 20)
        for index in 0..<2 {
            let decoded = try Self.frame(source, index)
            var worst = 0
            for (a, b) in zip(decoded.bytes, inputs[index].bytes) {
                worst = max(worst, abs(Int(a) - Int(b)))
            }
            #expect(worst <= 16)
        }
    }

    @Test func loopsForever() throws {
        let source = try Self.source(
            Self.encode([(Self.blocks(width: 8, height: 8, phase: 0), 10)]))
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test func lzwRoundTripsAcrossCodeSizeGrowthAndReset() {
        // Short runs among random bytes: the table both grows long strings and fills past 4,096.
        let indices = (0..<10_000).map { i -> UInt8 in
            let r = ScrollFixtures.mix(7, UInt64(i), 0)
            return r % 3 == 0 ? UInt8(i % 4) : UInt8(r >> 8 & 0xFF)
        }
        let encoded = GIFLZW.encode(indices, minimumCodeSize: 8)
        #expect(Self.lzwDecode(encoded, minimumCodeSize: 8) == indices)
    }

    @Test func quantiserIsExactForFewColours() {
        let pixels = (0..<1000).map { RGBA(r: UInt8($0 % 50 * 5), g: 9, b: 1, a: 255) }
        let palette = GIFQuantizer.palette(pixels, maximum: 255)
        #expect(palette.count == 50)
        let indices = GIFQuantizer.index(pixels, into: palette)
        #expect(indices.map { palette[Int($0)] } == pixels)
    }

    /// A reference GIF LZW decoder over the raw code stream (no sub-block framing).
    static func lzwDecode(_ bytes: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        var table: [[UInt8]] = []
        var codeSize = 0
        func reset() {
            table = (0..<clear).map { [UInt8($0)] } + [[], []]
            codeSize = minimumCodeSize + 1
        }
        reset()
        var output: [UInt8] = []
        var previous: [UInt8]?
        var bit = 0
        while bit + codeSize <= bytes.count * 8 {
            var code = 0
            for k in 0..<codeSize where bytes[(bit + k) / 8] >> ((bit + k) % 8) & 1 == 1 {
                code |= 1 << k
            }
            bit += codeSize
            if code == clear {
                reset()
                previous = nil
                continue
            }
            if code == end { break }
            guard let prior = previous else {
                output += table[code]
                previous = table[code]
                continue
            }
            let entry = code < table.count ? table[code] : prior + [prior[0]]
            if table.count < 4096 { table.append(prior + [entry[0]]) }
            if table.count == 1 << codeSize && codeSize < 12 { codeSize += 1 }
            output += entry
            previous = entry
        }
        return output
    }
}
