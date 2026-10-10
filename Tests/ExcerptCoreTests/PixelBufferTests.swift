import Testing

@testable import ExcerptCore

@Suite struct PixelBufferTests {
    @Test func roundTripsThroughCGImageExactly() {
        let image = Fixtures.rowStripes(width: 8, height: 300)
        let buffer = PixelBuffer(image)
        #expect(buffer.width == 8 && buffer.height == 300)
        #expect(buffer[x: 3, y: 0] == Fixtures.rowColor(0))
        #expect(buffer[x: 3, y: 299] == Fixtures.rowColor(299))
        #expect(PixelBuffer(buffer.makeImage()) == buffer)
    }

    @Test func fractionDifferingHonoursTolerance() {
        var a = PixelBuffer(Fixtures.rowStripes(width: 10, height: 10))
        var b = a
        b.bytes[0] &+= 2
        #expect(a.fractionDiffering(from: b, tolerance: 2) == 0)
        b.bytes[4] &+= 9
        #expect(a.fractionDiffering(from: b, tolerance: 2) == 0.01)
        a = b
        #expect(a.fractionDiffering(from: b, tolerance: 0) == 0)
    }
}
