import Testing

@testable import ExcerptCore

@Suite struct TilingTests {
    @Test func aCaptureThatFitsIsOneSpan() {
        #expect(Tiling.spans(length: 900, tile: 1_500) == [0..<900])
        #expect(Tiling.spans(length: 1_500, tile: 1_500) == [0..<1_500])
        #expect(Tiling.spans(length: 0, tile: 1_500).isEmpty)
    }

    @Test func aTallCaptureSplitsIntoFullTilesOverlappingAtLeastTheOverlap() {
        #expect(Tiling.spans(length: 1_501, tile: 1_500) == [0..<1500, 1..<1501])
        #expect(Tiling.spans(length: 2900, tile: 1_500) == [0..<1500, 1400..<2900])
        #expect(
            Tiling.spans(length: 10_000, tile: 1_500) == [
                0..<1500, 1400..<2900, 2800..<4300, 4200..<5700, 5600..<7100, 7000..<8500,
                8400..<9900, 8500..<10_000,
            ])
        for length in stride(from: 1501, through: 40_000, by: 37) {
            let spans = Tiling.spans(length: length, tile: 1_500)
            #expect(spans.first?.lowerBound == 0)
            #expect(spans.last?.upperBound == length)
            #expect(spans.allSatisfy { $0.count == 1_500 })
            for (a, b) in zip(spans, spans.dropFirst()) {
                #expect(b.lowerBound > a.lowerBound)
                #expect(a.upperBound - b.lowerBound >= Tiling.overlap)
            }
        }
    }

    /// Review focus: a line split across one tile boundary appears whole in the next tile.
    @Test func everyLineNoTallerThanTheOverlapIsWholeInSomeTile() {
        for length in [1501, 2900, 2901, 4321, 10_000] {
            let spans = Tiling.spans(length: length, tile: 1_500)
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
        for length in [900, 1501, 2900, 2901, 4300, 4301, 10_000] {
            let spans = Tiling.spans(length: length, tile: 1_500)
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
}
