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
