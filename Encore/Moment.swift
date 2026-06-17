import Foundation
import Photos
import CoreLocation

/// A "burst" — photos taken close together in time and place within one day.
/// A new burst starts on a >2h gap, a >4h span, or a >1km location jump.
/// On-device, from EXIF + GPS. A burst is "notable" when it has >3 photos.
struct Moment: Identifiable {
    let id: String          // "m-2019-0"
    let year: Int
    let photos: [MemoryPhoto]
    let placeName: String?

    var best: MemoryPhoto? { photos.max { $0.score.score < $1.score.score } }
    var isNotableBurst: Bool { photos.count > 3 }
}

extension YearMemory {
    /// Cluster this year's visible photos into bursts.
    var moments: [Moment] {
        let sorted = visiblePhotos.sorted {
            ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast)
        }
        guard !sorted.isEmpty else { return [] }

        var groups: [[MemoryPhoto]] = []
        var current: [MemoryPhoto] = [sorted[0]]
        for photo in sorted.dropFirst() {
            let prev = current.last!
            let date = photo.asset.creationDate ?? .distantPast
            let gap = date.timeIntervalSince(prev.asset.creationDate ?? .distantPast)
            let span = date.timeIntervalSince(current.first?.asset.creationDate ?? .distantPast)
            var farJump = false
            if let a = photo.location, let b = prev.location { farJump = a.distance(from: b) > 1000 }

            if gap > 7200 || span > 14400 || farJump {
                groups.append(current); current = [photo]
            } else {
                current.append(photo)
            }
        }
        groups.append(current)

        return groups.enumerated().map { index, photos in
            Moment(id: "m-\(year)-\(index)", year: year, photos: photos, placeName: placeName)
        }
    }
}
