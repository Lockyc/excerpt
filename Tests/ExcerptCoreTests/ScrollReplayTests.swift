import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

/// Real pages that failed a capture can't enter this public tree: `just stitch-replay <dir>`
/// replays every PNG in a local folder instead.
@Suite struct ScrollReplayTests {
    static let regionHeights = [240, 360, 480, 600, 720]
    static let pointers: [Double?] = [nil, 0.25, 0.5, 0.75, 0.9]

    @Test func aPageOfUniqueRowsReplaysToItsEndAtEveryRegionHeight() {
        let page = ScrollFixtures.page(width: 120, height: 900, seed: 4)
        let results = ScrollReplay.run(
            page: page, regionHeights: [180, 260], pointers: [nil])
        #expect(results.count == 2)
        for result in results { #expect(result.outcome == .reachedEnd, "\(result.combination)") }
    }

    @Test func aPageThatCannotStitchIsNeverReportedAsReachingItsEnd() {
        // Stripes repeat every 30 rows with nothing unique: no stitch of them is the page.
        let stripes = ScrollFixtures.stripes(width: 90, height: 600)
        for result in ScrollReplay.run(page: stripes, regionHeights: [200], pointers: [nil]) {
            if case .reachedEnd = result.outcome { Issue.record("stripes can't stitch exactly") }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXCERPT_REPLAY_DIR"] != nil))
    func everyLocalPageReplaysToItsEnd() throws {
        let pages = try ScrollReplay.localPages()
        #expect(!pages.isEmpty, "no PNGs in EXCERPT_REPLAY_DIR")
        for (name, page) in pages {
            for result in ScrollReplay.run(
                page: page, regionHeights: Self.regionHeights, pointers: Self.pointers)
            {
                switch result.outcome {
                case .reachedEnd: break
                case .halted(let phase):
                    // A halt fails safe, but it is the capture the replay exists to find.
                    Issue.record(
                        "\(name), \(result.combination): halted \(phase)", severity: .warning)
                case .wrong(let height):
                    Issue.record(
                        "\(name), \(result.combination): stitched \(height) rows, not the page")
                }
            }
        }
    }
}
