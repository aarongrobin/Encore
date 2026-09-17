import UIKit
import Photos

/// The personal loading-screen backdrop (build 49, MAR-41): one of the user's OWN photos from the
/// day being loaded, shown blurred behind "Finding your memories" instead of a stock picture.
///
/// Speed is the whole design. Decoding a library photo takes a beat, and the loading screen has to
/// draw at frame one, so the photo is prepared AHEAD of time: every launch picks a random photo for
/// today and each of the next seven days and saves a small JPEG in the app's Caches folder, keyed by
/// month-day. The next launch reads that file synchronously and the backdrop is on screen from the
/// first frame, with no picture change mid-load. Only a cache miss (first install, a long gap, a day
/// picked from the calendar) falls back to a live pick.
///
/// Everything stays on the device: the file is a downsized copy inside the app's own sandbox, the
/// system may purge it at will, and nothing is uploaded.
enum LoadingBackdrop {
    /// Long edge of the saved copy. Small on purpose: it is always drawn blurred, and a small file
    /// reads and decodes in a few milliseconds.
    private static let pixelSize: CGFloat = 900
    private static let daysAhead = 7
    private static let yearsToSearch = 30

    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("LoadingBackdrops", isDirectory: true)
    }

    /// "MM-dd": the backdrop belongs to a calendar day, not to a year.
    static func key(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)
    }

    private static func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent(key(for: date) + ".jpg")
    }

    /// The prepared backdrop for `date`, or nil on a cache miss. Synchronous and cheap.
    static func cached(for date: Date) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(for: date)) else { return nil }
        return UIImage(data: data)
    }

    private static func store(_ image: UIImage, for date: Date) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: date), options: .atomic)
    }

    // MARK: Picking

    /// Every non-screenshot photo taken on `date`'s month and day in past years.
    private static func assets(for date: Date) -> [PHAsset] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        var subpredicates: [NSPredicate] = []
        for year in (currentYear - yearsToSearch)..<currentYear {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            guard let start = calendar.date(from: comps),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            subpredicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                             start as NSDate, end as NSDate))
        }
        guard !subpredicates.isEmpty else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if !asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
        }
        return assets
    }

    private static func image(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // a single delivery, never the tiny degraded one
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false      // local only: a backdrop is not worth an iCloud wait
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: CGSize(width: pixelSize, height: pixelSize),
                                              contentMode: .aspectFit,
                                              options: options) { image, _ in completion(image) }
    }

    /// Live pick for a cache miss: a random photo from `date`, delivered on the main queue (nil when
    /// the day has no usable photo or the original is only in iCloud). The pick is also saved, so the
    /// same day opens instantly next time.
    static func pickRandom(for date: Date, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let asset = assets(for: date).randomElement() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            image(for: asset) { image in
                if let image { store(image, for: date) }
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    /// Prepare the coming week, off the main thread, once home is on screen. `todayCandidates` are
    /// today's VISIBLE photos (already scored, clutter removed), so the next open today draws a fresh
    /// random keeper. The days ahead have no scores yet, so they draw from every non-screenshot photo.
    /// Files outside the window are deleted.
    static func prepareUpcoming(todayCandidates: [PHAsset]) {
        DispatchQueue.global(qos: .utility).async {
            let calendar = Calendar.current
            let today = Date()
            var keep: Set<String> = []

            for offset in 0...daysAhead {
                guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                keep.insert(key(for: date) + ".jpg")
                let pool = (offset == 0 && !todayCandidates.isEmpty) ? todayCandidates : assets(for: date)
                guard let asset = pool.randomElement() else { continue }
                let done = DispatchSemaphore(value: 0)
                image(for: asset) { image in
                    if let image { store(image, for: date) }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 4)   // one at a time, so this never competes with the deck
            }

            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where !keep.contains(file) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
}
