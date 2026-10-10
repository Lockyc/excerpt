import Testing

@testable import ExcerptCore

@Suite struct AxisMapPlacementTests {
    let map = AxisMap(extent: 100, bands: [20..<50], gap: 10)

    @Test func keepsTheBands() {
        #expect(map.bands == [20..<50])
        #expect(map.extent == 100)
    }

    @Test func placesKeptPositionsLikeMap() {
        #expect(map.place(10, bias: .middle) == 10)
        #expect(map.place(60, bias: .after) == 40)
    }

    @Test func placesRemovedPositionsOnTheGapByBias() {
        #expect(map.place(35, bias: .before) == 20)
        #expect(map.place(35, bias: .after) == 30)
        #expect(map.place(35, bias: .middle) == 25)
        // A leading edge on the band's first line starts after the gap; a trailing edge on its
        // last boundary ends before it.
        #expect(map.place(20, bias: .after) == 30)
        #expect(map.place(50, bias: .before) == 20)
    }

    @Test func continuesPastTheEdges() {
        #expect(map.place(-7, bias: .middle) == -7)
        #expect(map.place(110, bias: .middle) == 90)
    }

    @Test func edgeBandsPlaceOnTheirGap() {
        let top = AxisMap(extent: 100, bands: [0..<30], gap: 10)
        #expect(top.place(0, bias: .after) == 10)
        #expect(top.place(0, bias: .before) == 0)
        let bottom = AxisMap(extent: 100, bands: [70..<100], gap: 10)
        #expect(bottom.place(100, bias: .after) == 80)
        #expect(bottom.place(100, bias: .before) == 70)
    }

    @Test func unmapInvertsKeptPositions() {
        for v in [0.0, 10, 20, 50, 75, 100] {
            #expect(map.unmap(map.map(v)!) == v)
        }
    }

    @Test func unmapOnAGapPicksTheNearerSide() {
        #expect(map.unmap(22) == 20)
        #expect(map.unmap(28) == 50)
        #expect(map.unmap(-3) == -3)
        #expect(map.unmap(85) == 105)
    }

    @Test func removedMeansWhollyInsideOneBand() {
        #expect(map.isRemoved(20, 50))
        #expect(map.isRemoved(25, 40))
        #expect(!map.isRemoved(15, 40))
        #expect(!map.isRemoved(25, 55))
    }
}
