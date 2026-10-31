import Foundation

/// A capture tile's corner label: how long ago it was taken, short enough to read newest
/// first, at a glance. Relative ("now", "4m", "3h", "Yest."), then the weekday for the rest of
/// the week, then a date.
public enum CaptureAge {
    public static func label(created: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(created)
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if calendar.isDate(created, inSameDayAs: now) { return "\(Int(elapsed / 3600))h" }

        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: created), to: calendar.startOfDay(for: now)
            ).day ?? 0
        if days == 1 { return "Yest." }
        if days <= 6 {
            return calendar.shortWeekdaySymbols[calendar.component(.weekday, from: created) - 1]
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat =
            calendar.isDate(created, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: created)
    }
}
