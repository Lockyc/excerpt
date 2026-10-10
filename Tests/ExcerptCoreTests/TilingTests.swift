import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct TilingTests {
    @Test func aCaptureThatFitsIsOneSpan() {
        #expect(Tiling.spans(length: 900) == [0..<900])
        #expect(Tiling.spans(length: 1568) == [0..<1568])
        #expect(Tiling.spans(length: 0).isEmpty)
    }

    @Test func aTallCaptureSplitsIntoFullTilesOverlappingAtLeastTheOverlap() {
        #expect(Tiling.spans(length: 1569) == [0..<1500, 69..<1569])
        #expect(Tiling.spans(length: 2900) == [0..<1500, 1400..<2900])
        #expect(
            Tiling.spans(length: 10_000) == [
                0..<1500, 1400..<2900, 2800..<4300, 4200..<5700, 5600..<7100, 7000..<8500,
                8400..<9900, 8500..<10_000,
            ])
        for length in stride(from: 1569, through: 40_000, by: 37) {
            let spans = Tiling.spans(length: length)
            #expect(spans.first?.lowerBound == 0)
            #expect(spans.last?.upperBound == length)
            #expect(spans.allSatisfy { $0.count == Tiling.tileLength })
            for (a, b) in zip(spans, spans.dropFirst()) {
                #expect(b.lowerBound > a.lowerBound)
                #expect(a.upperBound - b.lowerBound >= Tiling.overlap)
            }
        }
    }

    /// Review focus: a line split across one tile boundary appears whole in the next tile.
    @Test func everyLineNoTallerThanTheOverlapIsWholeInSomeTile() {
        for length in [1569, 2900, 2901, 4321, 10_000] {
            let spans = Tiling.spans(length: length)
            for top in 0...(length - Tiling.overlap) {
                let line = top..<(top + Tiling.overlap)
                #expect(
                    spans.contains {
                        $0.lowerBound <= line.lowerBound && line.upperBound <= $0.upperBound
                    },
                    "line \(line) of \(length)")
            }
        }
    }

    @Test func ownedBandsPartitionTheLengthAndHoldWholeLines() {
        for length in [900, 1569, 2900, 2901, 4300, 4301, 10_000] {
            let spans = Tiling.spans(length: length)
            let bands = Tiling.ownedBands(spans)
            #expect(bands.first?.lowerBound == 0)
            #expect(bands.last?.upperBound == length)
            for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
            for top in stride(from: 0, through: length - Tiling.overlap, by: 7) {
                let middle = top + Tiling.overlap / 2
                let owner = bands.firstIndex { $0.contains(middle) }!
                #expect(spans[owner].lowerBound <= top)
                #expect(top + Tiling.overlap <= spans[owner].upperBound)
            }
        }
    }

    @Test func tilesAreAtOnePixelPerPoint() {
        let image = Fixtures.sheet(width: 400, height: 6_000)
        let tiles = Tiling.tiles(of: image, scale: 2)
        #expect(tiles.count == 3)
        #expect(tiles.allSatisfy { $0.width == 200 && $0.height == Tiling.tileLength })
        #expect(Tiling.atPoints(image, scale: 2).height == 3_000)
    }

    @Test func aOneTimesCaptureThatFitsIsItself() {
        let image = Fixtures.sheet(width: 300, height: 800)
        let tiles = Tiling.tiles(of: image, scale: 1)
        #expect(tiles.count == 1)
        #expect(PixelBuffer(tiles[0]) == PixelBuffer(image))
    }

    /// A source in another pixel format still comes out as 8-bit sRGB RGBA, so a later PNG
    /// encode cannot fail on it.
    @Test func atPointsAlwaysNormalisesToEightBitSRGB() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)
        let context = CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: info.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let source = context.makeImage()!
        #expect(source.bitsPerComponent == 16)
        for scale in [1.0, 2.0] {
            let out = Tiling.atPoints(source, scale: scale)
            #expect(out.bitsPerComponent == 8 && out.bitsPerPixel == 32)
            #expect(out.colorSpace?.name == CGColorSpace.sRGB)
            #expect(PixelBuffer(out)[x: 0, y: 0] == RGBA(r: 255, g: 0, b: 0, a: 255))
        }
    }

    /// Each tile's first and last rows are the point rows its span names, including the
    /// pulled-back last tile.
    @Test(arguments: [(1, 4_000), (2, 4_000), (3, 4_000)])
    func tilesHoldTheRowsTheirSpansName(scale: Int, points: Int) {
        let image = Fixtures.paint(width: 12, height: points * scale) { _, y in
            Fixtures.rowColor(y / scale)
        }
        let tiles = Tiling.tiles(of: image, scale: Double(scale))
        let spans = Tiling.spans(length: points)
        #expect(tiles.count == spans.count && spans.count > 2)
        for (tile, span) in zip(tiles, spans) {
            let buffer = PixelBuffer(tile)
            #expect(buffer.height == span.count && buffer.width == 12 / scale)
            #expect(buffer[x: 1, y: 0] == Fixtures.rowColor(span.lowerBound))
            #expect(buffer[x: 1, y: span.count - 1] == Fixtures.rowColor(span.upperBound - 1))
        }
    }

    @Test func anOddPixelHeightRoundsToTheNearestPoint() {
        let image = Fixtures.sheet(width: 40, height: 1_001)
        #expect(Tiling.atPoints(image, scale: 2).height == 501)
    }

    @Test func aNonFiniteScaleIsOneTimes() {
        let image = Fixtures.sheet(width: 40, height: 100)
        #expect(Tiling.atPoints(image, scale: .nan).height == 100)
        #expect(Tiling.atPoints(image, scale: .infinity).height == 100)
    }
}
