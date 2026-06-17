import Foundation
import Photos
import CoreLocation

/// One photo plus everything we've inferred about it.
struct MemoryPhoto: Identifiable {
    let id: String          // PHAsset.localIdentifier
    let asset: PHAsset
    var score: PhotoScore
    var location: CLLocation?

    /// Final visibility decision: an explicit user choice always wins over the model.
    var isHidden: Bool {
        if let userWantsShown = PreferenceStore.shared.userOverride(for: id) {
            return !userWantsShown
        }
        return score.autoHidden
    }
}

/// All the memories from today's calendar date in a single past year:
/// photos, where you were, and what was on your calendar.
struct YearMemory: Identifiable {
    let id = UUID()
    let year: Int
    var allPhotos: [MemoryPhoto]
    var placeName: String?
    var isTravel: Bool
    var events: [MemoryEvent]

    var visiblePhotos: [MemoryPhoto] { allPhotos.filter { !$0.isHidden } }
    var hiddenPhotos: [MemoryPhoto] { allPhotos.filter { $0.isHidden } }

    /// The most interesting visible photo of this year (highest on-device score).
    var bestPhoto: MemoryPhoto? {
        visiblePhotos.max { $0.score.score < $1.score.score }
    }

    var yearsAgo: Int { Calendar.current.component(.year, from: Date()) - year }

    var headline: String {
        yearsAgo == 1 ? "1 year ago today" : "\(yearsAgo) years ago today"
    }

    var fullDateString: String {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year
        comps.month = cal.component(.month, from: Date())
        comps.day = cal.component(.day, from: Date())
        let date = cal.date(from: comps) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    /// True when there's something to show — photos or an interesting event.
    var hasContent: Bool { !visiblePhotos.isEmpty || !events.isEmpty }
}
