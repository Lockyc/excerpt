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
