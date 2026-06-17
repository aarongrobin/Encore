import Foundation
import UserNotifications

/// Schedules per-day local notifications with the real memory count for each
/// upcoming day. Re-run whenever the app opens to keep the rolling window fresh.
/// (No background task needed — this is more reliable than best-effort refresh.)
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let prefix = "encore-memory-"

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
    }

    /// Schedule one reminder per upcoming day that actually has memories.
    func reschedule(with counts: [(date: Date, count: Int)], hour: Int = 9, minute: Int = 0) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            // Clear our previously-scheduled day notifications, then re-add fresh ones.
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)

            let calendar = Calendar.current
            for entry in counts where entry.count > 0 {
                var comps = calendar.dateComponents([.year, .month, .day], from: entry.date)
                comps.hour = hour
                comps.minute = minute

                let content = UNMutableNotificationContent()
                content.title = "Encore"
                let noun = entry.count == 1 ? "memory" : "memories"
                content.body = "You have \(entry.count) \(noun) from this day. Take a look back."
                content.sound = .default
                content.badge = NSNumber(value: 1) // a single "new" dot, not a scary count

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let id = self.prefix + "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }

    /// Clear the red app-icon badge and drop already-delivered Encore notifications
    /// from Notification Center. Called once the user has opened and interacted.
    func clearBadge() {
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(0)
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(self.prefix) }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func disable() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        PreferenceStore.shared.dailyReminderEnabled = false
    }
}
