import Foundation
import EventKit

/// A calendar event worth resurfacing as a memory.
struct MemoryEvent: Identifiable {
    enum Category: String {
        case birthday, celebration, concert, travel, outing, generic
    }

    let id: String
    let year: Int
    let title: String
    let location: String?
    let category: Category

    var icon: String {
        switch category {
        case .birthday:    return "gift.fill"
        case .celebration: return "party.popper.fill"
        case .concert:     return "music.note"
        case .travel:      return "airplane"
        case .outing:      return "mappin.and.ellipse"
        case .generic:     return "calendar"
        }
    }
}

/// Surfaces interesting calendar events from this date in past years, on-device.
@MainActor
final class CalendarService {
    /// Master switch for calendar memories. Off for now (moved to the backlog):
    /// the plumbing stays intact, flip this to `true` to re-enable end to end.
    static let calendarEnabled = false

    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private static let inProgressKey = "calendarQueryInProgress"
    private static let disabledKey = "calendarQueryDisabled"

    /// Re-enable calendar querying (called when the user explicitly reconnects).
    func enableQuerying() {
        UserDefaults.standard.set(false, forKey: Self.disabledKey)
        UserDefaults.standard.set(false, forKey: Self.inProgressKey)
    }

    func memoryEvents() -> [MemoryEvent] {
        guard Self.calendarEnabled else { return [] }
        guard isAuthorized else { return [] }
        let defaults = UserDefaults.standard

        // Crash-loop breaker: if a prior query never completed, the app crashed
        // mid-query — disable calendar so it can open again. Reconnecting re-enables.
        if defaults.bool(forKey: Self.inProgressKey) {
            defaults.set(false, forKey: Self.inProgressKey)
            defaults.set(true, forKey: Self.disabledKey)
            return []
        }
        if defaults.bool(forKey: Self.disabledKey) { return [] }

        defaults.set(true, forKey: Self.inProgressKey)
        defaults.synchronize()

        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let currentYear = calendar.component(.year, from: now)

        var events: [MemoryEvent] = []
        for year in (currentYear - 15)..<currentYear {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day; comps.hour = 0
            guard let start = calendar.date(from: comps),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            for event in store.events(matching: predicate) {
                guard let category = classify(event) else { continue }
                events.append(
                    // Year-scoped: a recurring event repeats the same eventIdentifier
                    // across years, so scope by year to keep deck-item IDs unique.
                    MemoryEvent(id: "\(year)-" + (event.eventIdentifier ?? UUID().uuidString),
                                year: year,
                                title: event.title ?? "Event",
                                location: event.location,
                                category: category)
                )
            }
        }
        defaults.set(false, forKey: Self.inProgressKey)
        return events
    }

    /// Heuristic "is this an interesting memory?" classifier. Filters out the
    /// mundane work calendar; keeps celebrations, travel, outings with a place.
    private func classify(_ event: EKEvent) -> MemoryEvent.Category? {
        if event.status == .canceled { return nil }
        let title = (event.title ?? "").lowercased()
        let hasLocation = !(event.location?.isEmpty ?? true)

        let mundane = ["standup", "stand-up", "1:1", "1-1", "sync", "lunch meeting",
                       "meeting", "call", "interview", "review", "check-in", "checkin",
                       "stand up", "office hours", "scrum", "retro"]
        if mundane.contains(where: { title.contains($0) }) && !hasLocation { return nil }

        if title.contains("birthday") || title.contains("🎂") { return .birthday }
        if title.contains("wedding") || title.contains("anniversary") || title.contains("graduation")
            || title.contains("party") || title.contains("celebration") || title.contains("baby shower") {
            return .celebration
        }
        if title.contains("concert") || title.contains("festival") || title.contains("live")
            || title.contains("tour") || title.contains("game") || title.contains("show") {
            return .concert
        }
        if title.contains("flight") || title.contains("trip") || title.contains("vacation")
            || title.contains("✈️") || title.contains("hotel") || title.contains("airport")
            || title.contains("holiday") {
            return .travel
        }
        if hasLocation && !event.isAllDay { return .outing }
        return nil
    }
}
