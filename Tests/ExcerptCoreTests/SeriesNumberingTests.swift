import Foundation
import Testing

@testable import ExcerptCore

@Suite struct SeriesNumberingTests {
    @Test func stepsCarryOnAcrossTheSeries() {
        #expect(
            SeriesNumbering.firstSteps(
                stepCounts: [1, 2, 0, 1], restarts: [false, false, false, false]) == [1, 2, 1, 4])
    }

    @Test func aRestartBeginsAgainAtOne() {
        #expect(
            SeriesNumbering.firstSteps(stepCounts: [2, 1, 3], restarts: [false, true, false])
                == [1, 1, 2])
    }

    @Test func theFirstCaptureStartsAtOne() {
        #expect(SeriesNumbering.firstSteps(stepCounts: [2], restarts: [false]) == [1])
        #expect(SeriesNumbering.firstSteps(stepCounts: [], restarts: []) == [])
    }

    @Test func steplessCapturesKeepFirstStepOne() {
        #expect(
            SeriesNumbering.firstSteps(stepCounts: [3, 0], restarts: [false, false]) == [1, 1])
    }
}

@Suite struct SeriesOrderTests {
    let a = URL(fileURLWithPath: "/l/a.png")
    let b = URL(fileURLWithPath: "/l/b.png")
    let c = URL(fileURLWithPath: "/l/c.png")

    @Test func oldestFirstWithoutDuplicates() {
        let now = Date()
        let arranged = SeriesOrder.arrange(
            [(c, now), (a, now - 20), (b, now - 10), (a, now - 20)], open: [])
        #expect(arranged.series == [a, b, c] && arranged.alreadyOpen.isEmpty)
    }

    @Test func anOpenCaptureIsLeftOut() {
        let now = Date()
        let arranged = SeriesOrder.arrange([(a, now), (b, now + 1)], open: [a])
        #expect(arranged.series == [b] && arranged.alreadyOpen == [a])
    }
}

@Suite struct SeriesNumberingRestartTests {
    @Test func aRestartOnAStepLessCaptureIsIgnored() {
        #expect(
            SeriesNumbering.firstSteps(stepCounts: [2, 0, 1], restarts: [false, true, false])
                == [1, 1, 3])
    }
}
