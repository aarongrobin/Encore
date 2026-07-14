import Foundation

/// Persists the user's show/hide decisions and the signals we learn from them,
/// plus a cached "home" coordinate and the notification preference. All local.
final class PreferenceStore {
    static let shared = PreferenceStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let userShown = "userShownAssetIDs"
        static let userHidden = "userHiddenAssetIDs"
        static let showReasons = "showReasonCounts"
        static let hideReasons = "hideReasonCounts"
        static let dailyReminder = "dailyReminderEnabled"
        static let reminderHour = "reminderHour"
        static let reminderMinute = "reminderMinute"
        static let homeLat = "homeClusterLat"
        static let homeLon = "homeClusterLon"
        static let onboardingComplete = "onboardingComplete"
        static let likedAssets = "likedAssetIDs"
        static let notificationPromptShown = "notificationPromptShown"
    }

    // MARK: Liked photos (local only — we store the asset identifier, never the photo)

    var likedIDs: Set<String> { Set(defaults.stringArray(forKey: Keys.likedAssets) ?? []) }

    func isLiked(_ id: String) -> Bool { likedIDs.contains(id) }

    /// Toggle a photo's "liked" state. Returns the new state.
    @discardableResult
    func toggleLiked(_ id: String) -> Bool {
        var liked = likedIDs
        let nowLiked: Bool
        if liked.contains(id) { liked.remove(id); nowLiked = false }
        else { liked.insert(id); nowLiked = true }
        defaults.set(Array(liked), forKey: Keys.likedAssets)
        return nowLiked
    }

    // MARK: Reminder time (defaults to 9:00 AM)

    var reminderHour: Int {
        get { defaults.object(forKey: Keys.reminderHour) != nil ? defaults.integer(forKey: Keys.reminderHour) : 9 }
        set { defaults.set(newValue, forKey: Keys.reminderHour) }
    }
    var reminderMinute: Int {
        get { defaults.integer(forKey: Keys.reminderMinute) }
        set { defaults.set(newValue, forKey: Keys.reminderMinute) }
    }
    var reminderTime: Date {
        var comps = DateComponents(); comps.hour = reminderHour; comps.minute = reminderMinute
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// Whether the user has seen the privacy/permission intro.
    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Keys.onboardingComplete) }
        set { defaults.set(newValue, forKey: Keys.onboardingComplete) }
    }

    /// Whether we've shown the one-time "turn on a daily reminder" opt-in (build 39, MAR-45).
    /// Set true after the user makes any choice so it never asks twice.
    var notificationPromptShown: Bool {
        get { defaults.bool(forKey: Keys.notificationPromptShown) }
        set { defaults.set(newValue, forKey: Keys.notificationPromptShown) }
    }

    // MARK: Day log — a gentle record of days the user looked back (not streaks)

    private static let dayLogKey = "memoryDayLogDates"

    func recordDayCompleted() {
        var dates = Set(defaults.stringArray(forKey: Self.dayLogKey) ?? [])
        dates.insert(Self.todayKey())
        defaults.set(Array(dates), forKey: Self.dayLogKey)
    }

    var dayLogCount: Int {
        (defaults.stringArray(forKey: Self.dayLogKey) ?? []).count
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: Per-photo overrides (user decision beats the model)

    var shownIDs: Set<String> { Set(defaults.stringArray(forKey: Keys.userShown) ?? []) }
    var hiddenIDs: Set<String> { Set(defaults.stringArray(forKey: Keys.userHidden) ?? []) }

    /// Returns true if the user forced this photo visible, false if forced hidden, nil if no override.
    func userOverride(for id: String) -> Bool? {
        if shownIDs.contains(id) { return true }
        if hiddenIDs.contains(id) { return false }
        return nil
    }

    func markShown(_ id: String, reason: String?) {
        var shown = shownIDs; shown.insert(id)
        var hidden = hiddenIDs; hidden.remove(id)
        defaults.set(Array(shown), forKey: Keys.userShown)
        defaults.set(Array(hidden), forKey: Keys.userHidden)
        if let reason { bump(Keys.showReasons, reason) }
    }

    func markHidden(_ id: String, reason: String?) {
        var hidden = hiddenIDs; hidden.insert(id)
        var shown = shownIDs; shown.remove(id)
        defaults.set(Array(hidden), forKey: Keys.userHidden)
        defaults.set(Array(shown), forKey: Keys.userShown)
        if let reason { bump(Keys.hideReasons, reason) }
    }

    /// Aggregated reason tallies — the seed of "learning" what this user cares about.
    var showReasonCounts: [String: Int] { defaults.dictionary(forKey: Keys.showReasons) as? [String: Int] ?? [:] }
    var hideReasonCounts: [String: Int] { defaults.dictionary(forKey: Keys.hideReasons) as? [String: Int] ?? [:] }

    private func bump(_ key: String, _ reason: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        dict[reason, default: 0] += 1
        defaults.set(dict, forKey: key)
    }

    // MARK: Notification preference

    var dailyReminderEnabled: Bool {
        get { defaults.bool(forKey: Keys.dailyReminder) }
        set { defaults.set(newValue, forKey: Keys.dailyReminder) }
    }

    // MARK: Cached home location (rough cluster center, coordinates only)

    func saveHome(lat: Double, lon: Double) {
        defaults.set(lat, forKey: Keys.homeLat)
        defaults.set(lon, forKey: Keys.homeLon)
    }

    var home: (lat: Double, lon: Double)? {
        guard defaults.object(forKey: Keys.homeLat) != nil else { return nil }
        return (defaults.double(forKey: Keys.homeLat), defaults.double(forKey: Keys.homeLon))
    }
}
