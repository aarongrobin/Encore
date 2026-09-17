import SwiftUI

/// The manual date selector (build 48, MAR-48; simplified in build 49). Twelve months, the current
/// one on top, scrolling back in time. It is a date picker, not a streak view (Aaron, 09-17): no
/// years, no looked-back/missed marks. Tapping any day up to today re-aims the whole app at that
/// date. Future days are disabled: those memories arrive on their own day.
struct DayCalendarView: View {
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current
    private let viewingKey = MemoryDay.key(for: MemoryDay.current)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    /// First-of-month dates, newest first: the current month opens at the top and scrolling goes
    /// back in time, since a missed day is almost always a recent one.
    private var months: [Date] {
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(months, id: \.self) { month in
                            monthSection(month).id(month)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                // The current month is already at the top. Only jump when a day from an earlier
                // month is on screen.
                .onAppear {
                    let target = calendar.date(from: calendar.dateComponents([.year, .month], from: MemoryDay.current))
                    if let target, target != months.first { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .navigationTitle("Choose a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !MemoryDay.isToday {
                        Button("Today") { pick(nil) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func monthSection(_ month: Date) -> some View {
        let formatter = DateFormatter(); formatter.dateFormat = "MMMM"
        return VStack(alignment: .leading, spacing: 10) {
            Text(formatter.string(from: month))
                .font(.system(.title3, design: .serif).weight(.semibold))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                // Leading blanks so day 1 lands under its weekday.
                ForEach(0..<leadingBlanks(for: month), id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(days(in: month), id: \.self) { day in dayCell(day) }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let key = MemoryDay.key(for: day)
        let isFuture = day > Date()
        let isToday = calendar.isDateInToday(day)
        let isViewing = key == viewingKey

        return Button { pick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(isToday || isViewing ? .bold : .regular))
                .foregroundStyle(isViewing ? Color.white : (isFuture ? Color.secondary.opacity(0.4) : Color.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background {
                    // The day on screen is filled; today (when it is not the one on screen) is ringed.
                    Circle().fill(isViewing ? Color.accentColor : Color.clear)
                }
                .overlay {
                    if isToday && !isViewing {
                        Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(accessibilityLabel(day, viewing: isViewing, today: isToday))
    }

    private func accessibilityLabel(_ day: Date, viewing: Bool, today: Bool) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MMMM d"
        var label = formatter.string(from: day)
        if today { label += ", today" }
        if viewing { label += ", showing now" }
        return label
    }

    private func pick(_ day: Date?) {
        dismiss()
        // Skip the reload when the pick is already on screen.
        let targetKey = MemoryDay.key(for: day ?? Date())
        guard targetKey != viewingKey else { return }
        // Let the sheet start dismissing before the root swaps to the loading screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { service.load(day: day) }
    }

    // MARK: Calendar math

    /// Weekday initials rotated to the user's first weekday (Sunday in the US, Monday elsewhere).
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private func leadingBlanks(for month: Date) -> Int {
        let weekday = calendar.component(.weekday, from: month)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private func days(in month: Date) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }
}
