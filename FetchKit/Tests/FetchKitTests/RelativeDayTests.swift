import Foundation
import Testing
@testable import FetchKit

/// Every boundary here is one the `Calendar` gets right and arithmetic on
/// `Date` gets wrong, which is the whole reason this is not `now - 86400`.
@Suite("Relative day")
struct RelativeDayTests {
    /// Fixed, so a test running at 23:59:59 does not read a different day from
    /// the one it wrote.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private let locale = Locale(identifier: "en_GB")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0)
    -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Today is a time, because the time is what tells today's rows apart")
    func todayIsATime() {
        let now = date(2026, 3, 2, 18, 30)
        let text = RelativeDay.text(
            for: date(2026, 3, 2, 14, 2), now: now, calendar: calendar, locale: locale)
        #expect(text.contains("14"))
        #expect(text.contains("02"))
        #expect(!text.contains("Mar"))
    }

    @Test("A minute past midnight today is still today, not yesterday")
    func justAfterMidnightIsToday() {
        let now = date(2026, 3, 2, 9, 0)
        let text = RelativeDay.text(
            for: date(2026, 3, 2, 0, 1), now: now, calendar: calendar, locale: locale)
        #expect(text != "Yesterday")
    }

    /// Two hours apart across a midnight is a different *day*, and the day is
    /// what the column is about.
    @Test("A minute before midnight is Yesterday, however recent it was")
    func justBeforeMidnightIsYesterday() {
        let now = date(2026, 3, 2, 0, 30)
        let text = RelativeDay.text(
            for: date(2026, 3, 1, 23, 59), now: now, calendar: calendar, locale: locale)
        #expect(text == "Yesterday")
    }

    @Test("Older than yesterday is a date, with no year inside this year")
    func olderIsADate() {
        let now = date(2026, 6, 1)
        let text = RelativeDay.text(
            for: date(2026, 3, 2), now: now, calendar: calendar, locale: locale)
        #expect(text.contains("2"))
        #expect(text.contains("Mar"))
        #expect(!text.contains("2026"))
    }

    /// "2 Mar" beside a list that also holds March of three years ago is a date
    /// that lies by omission.
    @Test("A different year carries its year")
    func anotherYearSaysSo() {
        let now = date(2026, 6, 1)
        let text = RelativeDay.text(
            for: date(2023, 3, 2), now: now, calendar: calendar, locale: locale)
        #expect(text.contains("2023"))
    }

    @Test("The last day of last year is Yesterday on New Year's Day")
    func yesterdayCrossesTheYear() {
        let now = date(2026, 1, 1, 10, 0)
        let text = RelativeDay.text(
            for: date(2025, 12, 31, 22, 0), now: now, calendar: calendar, locale: locale)
        #expect(text == "Yesterday")
    }
}
