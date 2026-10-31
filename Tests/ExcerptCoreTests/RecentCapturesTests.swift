import Foundation
import Testing

@testable import ExcerptCore

@Suite struct CaptureAgeTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 2026-11-05 15:00, a Thursday.
    var now: Date { date(2026, 11, 5, 15) }

    func label(_ created: Date, now: Date? = nil) -> String {
        CaptureAge.label(created: created, now: now ?? self.now, calendar: calendar)
    }

    @Test func secondsAgoIsNow() {
        #expect(label(now.addingTimeInterval(-30)) == "now")
        #expect(label(now.addingTimeInterval(10)) == "now")
    }

    @Test func minutesAgo() {
        #expect(label(now.addingTimeInterval(-4 * 60)) == "4m")
        #expect(label(now.addingTimeInterval(-59 * 60)) == "59m")
    }

    @Test func hoursAgoSameDay() {
        #expect(label(now.addingTimeInterval(-3 * 3600)) == "3h")
    }

    @Test func yesterday() {
        #expect(label(date(2026, 11, 4, 23)) == "Yest.")
        #expect(label(date(2026, 11, 5, 0, 30), now: date(2026, 11, 5, 1, 10)) == "40m")
    }

    @Test func thisWeek() {
        #expect(label(date(2026, 11, 1, 10)) == "Sun")
    }

    @Test func older() {
        #expect(label(date(2026, 10, 12)) == "12 Oct")
        #expect(label(date(2025, 10, 12)) == "12 Oct 2025")
    }
}

@Suite struct RecentLayoutTests {
    @Test func sevenTiles() {
        #expect(RecentLayout.tiles().count == RecentLayout.tileCount)
    }

    @Test func heroSpansTheWidthAndTheTopHalf() {
        let tiles = RecentLayout.tiles()
        let hero = tiles[0]
        #expect(hero.minX == RecentLayout.padding)
        #expect(hero.width == RecentLayout.side - 2 * RecentLayout.padding)
        #expect(hero.maxY == RecentLayout.side - RecentLayout.padding)
        #expect(tiles.dropFirst().allSatisfy { $0.maxY <= hero.minY })
        let rowHeight = tiles[1].height
        let twoRows = 2 * rowHeight + RecentLayout.gap
        #expect(abs(hero.height - twoRows) < 0.5)
    }

    @Test func smallTilesReadLeftToRightThenDown() {
        let tiles = RecentLayout.tiles()
        let upper = Array(tiles[1...3])
        let lower = Array(tiles[4...6])
        #expect(Set(upper.map(\.minY)).count == 1)
        #expect(Set(lower.map(\.minY)).count == 1)
        #expect(upper[0].minY > lower[0].minY)
        for row in [upper, lower] {
            #expect(row[0].minX < row[1].minX && row[1].minX < row[2].minX)
        }
    }

    @Test func nothingOverlapsAndAllInsideAboveTheFooter() {
        let side = RecentLayout.side
        let tiles = RecentLayout.tiles()
        let footer = RecentLayout.footer()
        let panel = CGRect(x: 0, y: 0, width: side, height: side)
        for (index, tile) in tiles.enumerated() {
            #expect(panel.contains(tile))
            #expect(!tile.intersects(footer))
            for other in tiles[(index + 1)...] { #expect(!tile.intersects(other)) }
        }
    }
}
