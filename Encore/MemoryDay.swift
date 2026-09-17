import Foundation

/// The calendar day Encore is currently showing (build 48, MAR-48). Normally today; the manual
/// date selector points it at a missed day instead. Everything that used to read `Date()` for the
/// "on this day" month/day (the photo query, captions, the home date block, the day log) reads
/// `MemoryDay.current`, so one assignment re-aims the whole app. Not persisted: a fresh launch
/// always opens on today.
enum MemoryDay {
    /// The user-picked day, or nil when viewing today. Set on the main actor by
    /// `PhotoLibraryService.load(day:)` BEFORE the background fetch starts reading `current`.
    private static var selected: Date?

    static var current: Date { selected ?? Date() }

    static var isToday: Bool {
        guard let selected else { return true }
        return Calendar.current.isDateInToday(selected)
    }

    /// Point the app at `date`. Picking today (or nil) clears the selection so `current` keeps
    /// tracking the real clock.
    static func select(_ date: Date?) {
        if let date, !Calendar.current.isDateInToday(date) {
            selected = Calendar.current.startOfDay(for: date)
        } else {
            selected = nil
        }
    }

    /// "9 years ago today" on today, "9 years ago" on a picked day (where "today" would be wrong).
    static func yearsAgoText(_ yearsAgo: Int) -> String {
        let base = yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
        return isToday ? base + " today" : base
    }

    /// "yyyy-MM-dd" key for the day log.
    static func key(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
