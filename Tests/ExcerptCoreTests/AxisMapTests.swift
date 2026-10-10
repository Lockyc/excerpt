import Testing

@testable import ExcerptCore

@Suite struct AxisMapTests {
    @Test func identityWithoutBands() {
        let map = AxisMap(extent: 100, bands: [], gap: 10)
        #expect(map.segments == [.init(source: 0..<100, destination: 0)])
        #expect(map.gaps.isEmpty)
        #expect(map.renderedLength == 100)
        #expect(map.map(42) == 42)
    }

    @Test func oneBandBecomesAGap() {
        let map = AxisMap(extent: 100, bands: [20..<50], gap: 10)
        #expect(
            map.segments == [
                .init(source: 0..<20, destination: 0), .init(source: 50..<100, destination: 30),
            ])
        #expect(map.gaps == [.init(destination: 20..<30, removed: 30)])
        #expect(map.renderedLength == 80)
    }

    @Test func mapsAcrossTheGap() {
        let map = AxisMap(extent: 100, bands: [20..<50], gap: 10)
        #expect(map.map(10) == 10)
        #expect(map.map(20) == 20)  // the boundary belongs to the kept side before it
        #expect(map.map(35) == nil)  // inside the removed band
        #expect(map.map(50) == 30)
        #expect(map.map(100) == 80)  // far edge
    }

    @Test func edgeBandsHaveOneKeptSide() {
        let top = AxisMap(extent: 100, bands: [0..<30], gap: 10)
        #expect(top.segments == [.init(source: 30..<100, destination: 10)])
        #expect(top.gaps == [.init(destination: 0..<10, removed: 30)])
        #expect(top.renderedLength == 80)
        let bottom = AxisMap(extent: 100, bands: [70..<100], gap: 10)
        #expect(bottom.renderedLength == 80)
        #expect(bottom.gaps == [.init(destination: 70..<80, removed: 30)])
    }
}
