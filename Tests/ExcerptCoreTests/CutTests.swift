import Foundation
import Testing

@testable import ExcerptCore

@Suite struct CutTests {
    @Test func keepsOnlyTheRequestedAxis() {
        let cuts = [
            Cut(axis: .horizontal, lower: 10, upper: 20), Cut(axis: .vertical, lower: 5, upper: 8),
        ]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [10..<20])
        #expect(CutSet.normalized(cuts, axis: .vertical, extent: 100) == [5..<8])
    }

    @Test func mergesOverlappingAndTouchingAndSorts() {
        let cuts = [
            Cut(axis: .horizontal, lower: 50, upper: 60),
            Cut(axis: .horizontal, lower: 10, upper: 20),
            Cut(axis: .horizontal, lower: 15, upper: 30),
            Cut(axis: .horizontal, lower: 30, upper: 35),
        ]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [10..<35, 50..<60])
    }

    @Test func clampsToExtentAndDropsEmpty() {
        let cuts = [
            Cut(axis: .horizontal, lower: -5, upper: 3),
            Cut(axis: .horizontal, lower: 90, upper: 130),
            Cut(axis: .horizontal, lower: 40, upper: 40),
            Cut(axis: .horizontal, lower: 70, upper: 60),
        ]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [0..<3, 90..<100])
    }

    @Test func dropsABandWhollyBeyondTheExtent() {
        let cuts = [Cut(axis: .horizontal, lower: 120, upper: 130)]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [])
    }

    @Test func dropsABandWhollyBeforeZero() {
        let cuts = [
            Cut(axis: .horizontal, lower: -20, upper: -10),
            Cut(axis: .horizontal, lower: -5, upper: -1),
        ]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [])
    }

    @Test func ignoresABandCoveringTheWholeExtent() {
        let cuts = [
            Cut(axis: .horizontal, lower: 0, upper: 60),
            Cut(axis: .horizontal, lower: 50, upper: 100),
        ]
        #expect(CutSet.normalized(cuts, axis: .horizontal, extent: 100) == [])
    }

    @Test func roundTripsThroughJSON() throws {
        let cut = Cut(axis: .vertical, lower: 3, upper: 9)
        let data = try JSONEncoder().encode(cut)
        #expect(try JSONDecoder().decode(Cut.self, from: data) == cut)
    }
}
