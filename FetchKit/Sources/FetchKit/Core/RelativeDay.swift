import Foundation

/**
 When something happened, said as briefly as the day allows.

 The Downloads list is sorted newest first and, until this, said so without
 evidence: a list claiming an order with no date on it is asking to be
 trusted. Today's rows carry the time, because that is the part that
 distinguishes them from each other; yesterday's say `Yesterday`, because
 "17:04" a day later is a time you cannot place; anything older is a date.

 Pure, and here rather than in the view, because the app target has no test
 bundle and "which day is that" is arithmetic with three edge cases — a
 midnight boundary, a year boundary, and a clock the user may have moved.
 */
public enum RelativeDay {
    /**
     `now` and `calendar` are parameters so the boundaries can be tested at
     all. Defaulting them keeps every call site a single argument.
     */
    public static func text(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(
            date: .omitted, time: .omitted,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone)

        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(
                style.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(style.day().month(.abbreviated))
            : date.formatted(style.day().month(.abbreviated).year())
    }
}
