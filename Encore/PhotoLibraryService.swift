import Foundation
import Photos
import CoreLocation
import UIKit

/// Orchestrates the whole "on this day" experience: fetch photos taken on today's
/// date in past years, score them on-device, attach location + calendar context,
/// and publish a list of year-by-year memories. Everything stays on the device.
@MainActor
final class PhotoLibraryService: ObservableObject {

    enum LoadState {
        case idle
        case requestingAccess
        case denied
        case loading
        case loaded([YearMemory])
        case empty
    }

    @Published var state: LoadState = .idle
    @Published var hasLimitedAccess = false
    @Published var calendarAuthorized = false
    @Published var reminderEnabled = false

    /// The home cover's peek hero image, decoded at screen resolution BEFORE the loading screen
    /// is dismissed. The home page reads this so it appears with the photo already on screen —
    /// no white placeholder, no async pop-in. Keyed by the asset's localIdentifier so the home
    /// page can confirm it matches the asset it is about to draw.
    @Published private(set) var peekHeroImage: UIImage?
    @Published private(set) var peekHeroAssetID: String?

    /// An AI-picked "cool" memory from a past year, decoded at screen resolution while the
    /// loading screen is up and shown softly behind the "Finding your memories" text. Picked from
    /// the FIRST batch of scored photos (biased to people/travel/celebration, lightly randomized)
    /// so it does not delay the load. Nil until a candidate is scored; the loading screen shows its
    /// plain state until then, then gently reveals this. Keyed by localIdentifier so the home cover
    /// can reuse the decode if the teaser happens to be the peek hero.
    @Published private(set) var teaserImage: UIImage?
    @Published private(set) var teaserAssetID: String?

    private let imageManager = PHCachingImageManager()
    private let locationResolver = LocationResolver()
    private let calendarService = CalendarService()
    private let yearsToSearch = 30

    init() {
        calendarAuthorized = calendarService.isAuthorized
        reminderEnabled = PreferenceStore.shared.dailyReminderEnabled
    }

    // MARK: - Authorization

    func start() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            hasLimitedAccess = false
            loadMemories()
        case .limited:
            hasLimitedAccess = true
            loadMemories()
        case .notDetermined:
            state = .requestingAccess
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor in
                    guard let self else { return }
                    switch newStatus {
                    case .authorized: self.hasLimitedAccess = false; self.loadMemories()
                    case .limited:    self.hasLimitedAccess = true;  self.loadMemories()
                    default:          self.state = .denied
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func connectCalendar() {
        calendarService.enableQuerying()
        calendarService.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.calendarAuthorized = granted
                if granted { self.loadMemories() }
            }
        }
    }

    func toggleReminder() {
        setReminder(enabled: !reminderEnabled,
                    hour: PreferenceStore.shared.reminderHour,
                    minute: PreferenceStore.shared.reminderMinute)
    }

    /// Enable/disable the daily reminder at a specific time.
    func setReminder(enabled: Bool, hour: Int, minute: Int) {
        PreferenceStore.shared.reminderHour = hour
        PreferenceStore.shared.reminderMinute = minute

        if enabled {
            NotificationManager.shared.requestAuthorization { [weak self] granted in
                guard let self else { return }
                self.reminderEnabled = granted
                PreferenceStore.shared.dailyReminderEnabled = granted
                if granted { self.refreshSchedule() }
            }
        } else {
            NotificationManager.shared.disable()
            reminderEnabled = false
        }
    }

    /// Recompute upcoming memory counts and refresh the notification schedule.
    /// Safe to call on every app open; no-ops if the reminder is off.
    func refreshSchedule() {
        guard PreferenceStore.shared.dailyReminderEnabled else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let counts = self.upcomingMemoryCounts(days: 14)
            Task { @MainActor in
                NotificationManager.shared.reschedule(with: counts,
                                                      hour: PreferenceStore.shared.reminderHour,
                                                      minute: PreferenceStore.shared.reminderMinute)
            }
        }
    }

    /// Photo memory counts (excluding screenshots) for each of the next `days` days.
    private func upcomingMemoryCounts(days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        var result: [(Date, Int)] = []
        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: Date()) else { continue }
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            result.append((date, memoryCount(month: month, day: day)))
        }
        return result
    }

    /// Fast count of resurfaceable photos (screenshots excluded) for a month/day across past years.
    private func memoryCount(month: Int, day: Int) -> Int {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        var subpredicates: [NSPredicate] = []
        for year in (currentYear - yearsToSearch)..<currentYear {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 0; comps.minute = 0; comps.second = 0
            guard let start = calendar.date(from: comps),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            subpredicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                             start as NSDate, end as NSDate))
        }
        guard !subpredicates.isEmpty else { return 0 }

        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var count = 0
        result.enumerateObjects { asset, _, _ in
            if !asset.mediaSubtypes.contains(.photoScreenshot) { count += 1 }
        }
        return count
    }

    /// Re-evaluate visibility after the user shows/hides photos.
    func refreshVisibility() {
        if case .loaded(let memories) = state {
            // YearMemory recomputes visible/hidden from PreferenceStore, so just nudge SwiftUI.
            state = .loaded(memories)
        }
    }

    // MARK: - Loading

    func loadMemories() {
        state = .loading
        teaserImage = nil
        teaserAssetID = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.locationResolver.ensureHomeComputed()

            let calendar = Calendar.current
            let today = Date()
            let currentYear = calendar.component(.year, from: today)
            let month = calendar.component(.month, from: today)
            let day = calendar.component(.day, from: today)

            // OR a 24h creationDate window per past year (PhotoKit can't match month/day directly).
            var subpredicates: [NSPredicate] = []
            for year in (currentYear - self.yearsToSearch)..<currentYear {
                var comps = DateComponents()
                comps.year = year; comps.month = month; comps.day = day
                comps.hour = 0; comps.minute = 0; comps.second = 0
                guard let start = calendar.date(from: comps),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
                subpredicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                                 start as NSDate, end as NSDate))
            }

            var assetsByYear: [Int: [PHAsset]] = [:]
            if !subpredicates.isEmpty {
                let options = PHFetchOptions()
                options.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: .image, options: options)
                result.enumerateObjects { asset, _, _ in
                    guard let date = asset.creationDate else { return }
                    let y = calendar.component(.year, from: date)
                    assetsByYear[y, default: []].append(asset)
                }
            }

            // Calendar events (main-actor isolated service)
            let allAssets = assetsByYear.flatMap { $0.value }
            let assetsByID = Dictionary(allAssets.map { ($0.localIdentifier, $0) },
                                        uniquingKeysWith: { first, _ in first })

            self.scoreAll(allAssets, onBatch: { partial in
                self.pickAndDecodeTeaser(from: partial, assetsByID: assetsByID)
            }) { scores in
                Task { @MainActor in
                    let eventsByYear = Dictionary(grouping: self.calendarService.memoryEvents(), by: { $0.year })
                    self.assemble(assetsByYear: assetsByYear, scores: scores, eventsByYear: eventsByYear, calendar: calendar)
                }
            }
        }
    }

    private func assemble(assetsByYear: [Int: [PHAsset]],
                          scores: [String: PhotoScore],
                          eventsByYear: [Int: [MemoryEvent]],
                          calendar: Calendar) {
        let years = Set(assetsByYear.keys).union(eventsByYear.keys)
        var memories: [YearMemory] = []

        for year in years {
            let assets = assetsByYear[year] ?? []
            let photos: [MemoryPhoto] = assets.map { asset in
                MemoryPhoto(id: asset.localIdentifier,
                            asset: asset,
                            score: scores[asset.localIdentifier]
                                ?? PhotoScore(score: 0.5, isScreenshot: false, reason: nil),
                            location: asset.location)
            }
            var memory = YearMemory(year: year, allPhotos: photos, placeName: nil,
                                    isTravel: false, events: eventsByYear[year] ?? [])
            if let loc = dominantLocation(photos) {
                memory.isTravel = locationResolver.isTravel(loc)
            }
            memories.append(memory)
        }

        memories.sort { $0.year > $1.year }
        let usable = memories.filter { $0.hasContent }

        guard !usable.isEmpty else { state = .empty; return }

        // GATE (build 36): hold the loading screen until the opening is genuinely wait-free AND the
        // teaser has had real screen time. The author's note: "Make sure everything loads before
        // proceeding to the home screen, which will be ok because the waiting screen is more
        // engaging." We wait on THREE things — the home cover hero decoded, the AI teaser decoded
        // (so it reads as an engaging backdrop, not a flash), and the warmed front deck cached — so
        // the first swipe-through is zero-wait. An overall timeout (`loadGateTimeout`) caps the wait
        // so a huge day / slow iCloud can never hang it. The REST of the deck is background-cached
        // only AFTER the home appears, so the warm-up doesn't compete with the cover decode.
        let ordered = deckOrderedAssets(usable)
        let frontSet = Array(ordered.prefix(deckWarmCount))

        var proceeded = false
        let proceed: () -> Void = { [weak self] in
            guard let self, !proceeded else { return }
            proceeded = true
            self.state = .loaded(usable)
            self.startCaching(for: Array(ordered.dropFirst(self.deckWarmCount)))
            self.resolvePlaceNames(for: usable)
        }

        // Two of the three gate conditions resolve asynchronously and we proceed when BOTH are in
        // (hero is the third, awaited inside the group below). The teaser may already be decoded by
        // now (it's picked from the first scored batch); if it never resolves, the timeout covers it.
        let group = DispatchGroup()
        group.enter(); group.enter()   // hero, front-deck
        var leftHero = false, leftFront = false
        let leaveHero = { if !leftHero { leftHero = true; group.leave() } }
        let leaveFront = { if !leftFront { leftFront = true; group.leave() } }

        prefetchHomeCover(for: usable) { leaveHero() }
        warmDeckFront(frontSet) { leaveFront() }

        group.notify(queue: .main) {
            // Hold a touch longer if the teaser hasn't landed yet, so in the normal case it clearly
            // displays rather than flashing. Bounded by the overall timeout below.
            if self.teaserImage != nil {
                proceed()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.teaserGraceWait) { proceed() }
            }
        }

        // Hard cap: whatever is still pending (slow iCloud, a teaser that can't be picked), the home
        // appears by now so the wait is engaging, not interminable.
        DispatchQueue.main.asyncAfter(deadline: .now() + loadGateTimeout) { proceed() }
    }

    /// Number of deck photos to warm at full-screen size during the loading screen (build 36). A
    /// generous front set so the whole opening swipe-through (home → several years) is genuinely
    /// zero-wait. The loading screen now WAITS for these to be cached before dismissing, so it must
    /// stay bounded by `loadGateTimeout` for a huge day.
    private let deckWarmCount = 22
    /// Overall cap on how long the loading screen holds for the gate (build 36). Long enough for the
    /// teaser to read and the front deck to warm; short enough that a slow iCloud can't hang it.
    private let loadGateTimeout: TimeInterval = 9
    /// If the hero + front deck are ready but the teaser hasn't decoded yet, hold this much longer so
    /// the teaser clearly shows instead of flashing. Still bounded by `loadGateTimeout`.
    private let teaserGraceWait: TimeInterval = 1.2

    /// The deck's photos in the exact order the user pages them: newest year first, each year's
    /// moments in order, each moment's photos chronological — mirroring `MemoryDeckView.rebuild`.
    /// Used to warm the FRONT of the deck first so the opening swipes never wait.
    private func deckOrderedAssets(_ memories: [YearMemory]) -> [PHAsset] {
        memories.flatMap { memory in
            memory.moments.flatMap { $0.photos.map(\.asset) }
        }
    }

    /// Warm the front of the deck at full-screen display size (the exact size `MemoryPageView`
    /// requests), so the first swipes hand off straight from cache with no decode wait. `done`
    /// fires once every front asset has a non-degraded (fully decoded) result in hand, so the
    /// load gate can WAIT for the opening swipe-through to be genuinely zero-wait (build 36).
    /// startCachingImages keeps them resident; the per-asset requests are what tell us when each
    /// is actually decoded. Guarded so `done` runs exactly once even with multiple deliveries.
    private func warmDeckFront(_ assets: [PHAsset], done: @escaping () -> Void = {}) {
        guard !assets.isEmpty else { done(); return }
        let scale = UIScreen.main.scale
        let screenPx = CGSize(width: UIScreen.main.bounds.width * scale,
                              height: UIScreen.main.bounds.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        imageManager.startCachingImages(for: assets, targetSize: screenPx,
                                        contentMode: .aspectFill, options: options)

        let group = DispatchGroup()
        for asset in assets {
            group.enter()
            var left = false
            imageManager.requestImage(for: asset, targetSize: screenPx,
                                      contentMode: .aspectFill, options: options) { _, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !left else { return }
                left = true
                group.leave()
            }
        }
        group.notify(queue: .main, execute: done)
    }

    /// The home cover's peek hero = the chronologically-first photo of the first Moment of the
    /// most-recent year that has photos. Must match `MemoryDeckView.firstPhoto` so the decoded
    /// image we hand the home page is exactly the one the peek draws.
    private func peekHeroAsset(in memories: [YearMemory]) -> PHAsset? {
        for memory in memories {
            for moment in memory.moments where moment.photos.first != nil {
                return moment.photos.first?.asset
            }
        }
        return memories.flatMap { $0.visiblePhotos }
            .max { $0.score.score < $1.score.score }?.asset
    }

    /// Decode the peek hero at screen resolution (high quality, same request the peek makes) so
    /// it is in hand before home appears. Warms the first row of mosaic tiles in parallel. Calls
    /// `done` once the hero is decoded; a short timeout guarantees the app still proceeds if a
    /// huge iCloud original is mid-download, in which case the peek falls back to its own async
    /// load at whatever quality resolves.
    private func prefetchHomeCover(for memories: [YearMemory], done: @escaping () -> Void) {
        guard let hero = peekHeroAsset(in: memories) else { done(); return }

        let mosaic = memories.flatMap { $0.moments }.prefix(6).compactMap { $0.best?.asset }
        if !mosaic.isEmpty {
            let tileOptions = PHImageRequestOptions()
            tileOptions.deliveryMode = .highQualityFormat
            tileOptions.isNetworkAccessAllowed = true
            let tilePx = CGSize(width: 140 * UIScreen.main.scale, height: 140 * UIScreen.main.scale)
            imageManager.startCachingImages(for: Array(mosaic), targetSize: tilePx,
                                            contentMode: .aspectFill, options: tileOptions)
        }

        let scale = UIScreen.main.scale
        let screenPx = CGSize(width: UIScreen.main.bounds.width * scale,
                              height: UIScreen.main.bounds.height * scale)

        var finished = false
        let finish: (UIImage?) -> Void = { [weak self] image in
            guard !finished else { return }
            finished = true
            if let image, let self {
                self.peekHeroImage = image
                self.peekHeroAssetID = hero.localIdentifier
            }
            done()
        }

        // Same high-quality, exact request the peek uses, so its later AsyncPHImage load returns
        // the identical cached result instantly even on the fallback path.
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        imageManager.requestImage(for: hero, targetSize: screenPx,
                                  contentMode: .aspectFill, options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }
            Task { @MainActor in finish(image) }
        }

        // Fallback so a stalled iCloud download can't pin the loading screen forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
    }

    /// Bump specific assets to the front of the cache (e.g. a scrubber jump target).
    func prioritize(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(for: assets,
                                        targetSize: CGSize(width: 1400, height: 1900),
                                        contentMode: .aspectFill,
                                        options: options)
    }

    /// Background-cache the REST of the deck (everything past the warmed front) at full-screen
    /// display size so later swipes are instant too. Called AFTER the home appears so it never
    /// competes with the cover decode or lengthens the loading screen.
    private func startCaching(for assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        let scale = UIScreen.main.scale
        let screenPx = CGSize(width: UIScreen.main.bounds.width * scale,
                              height: UIScreen.main.bounds.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        imageManager.startCachingImages(for: assets, targetSize: screenPx,
                                        contentMode: .aspectFill, options: options)
    }

    private func dominantLocation(_ photos: [MemoryPhoto]) -> CLLocation? {
        photos.compactMap { $0.location }.first
    }

    /// Per-MOMENT place names, keyed by `Moment.id`. Each moment geocodes its OWN dominant
    /// location, so a photo taken in a different city the same day shows ITS city — not the
    /// year's first-photo city, which was the wrong-city bug. The deck/share captions read
    /// from here first, falling back to the year-level `placeName` only when a moment has no
    /// coordinate of its own.
    @Published private(set) var momentPlaces: [String: String] = [:]

    /// Reverse-geocode each year's dominant location (for the gallery year header) AND each
    /// Moment's OWN dominant location (for the per-photo share caption), sequentially so we
    /// respect the geocoder's rate limits.
    private func resolvePlaceNames(for memories: [YearMemory]) {
        var working = memories

        // Build the full job list up front: one job per year (updates YearMemory.placeName) and
        // one per moment (updates momentPlaces[moment.id]). Each job carries its OWN location.
        enum Job {
            case year(Int, CLLocation)
            case moment(String, CLLocation)
        }
        var jobs: [Job] = []
        for (yi, memory) in working.enumerated() {
            if let loc = dominantLocation(memory.allPhotos) { jobs.append(.year(yi, loc)) }
            for moment in memory.moments {
                if let loc = dominantLocation(moment.photos) { jobs.append(.moment(moment.id, loc)) }
            }
        }

        func process(_ index: Int) {
            guard index < jobs.count else { return }
            let job = jobs[index]
            let loc: CLLocation
            switch job {
            case .year(_, let l):   loc = l
            case .moment(_, let l): loc = l
            }
            locationResolver.placeName(for: loc) { [weak self] name in
                guard let self else { return }
                if let name {
                    switch job {
                    case .year(let yi, _):
                        if yi < working.count { working[yi].placeName = name }
                        if case .loaded = self.state { self.state = .loaded(working) }
                    case .moment(let id, _):
                        self.momentPlaces[id] = name
                    }
                }
                process(index + 1)
            }
        }
        process(0)
    }

    // MARK: - Loading-screen teaser (on-device AI pick)

    /// Pick a "cool" memory from the first scored batch and decode it for the loading-screen
    /// backdrop. The score already bakes in the people/travel/celebration bias (PhotoScorer boosts
    /// faces, beach/mountain/sunset/travel/party/wedding scenes and penalizes screenshots/text), so
    /// we take the top-scoring non-clutter candidates and pick ONE at random among them. The
    /// randomness makes the tease feel fresh each launch instead of always surfacing the single
    /// highest score. Fully on-device; only runs once (guarded on `teaserAssetID`).
    private func pickAndDecodeTeaser(from scores: [String: PhotoScore],
                                     assetsByID: [String: PHAsset]) {
        Task { @MainActor in
            guard self.teaserAssetID == nil else { return }

            let candidates = scores
                .filter { !$0.value.isScreenshot && $0.value.score >= 0.5 }
                .sorted { $0.value.score > $1.value.score }
                .prefix(6)
                .compactMap { assetsByID[$0.key] }

            guard let chosen = candidates.randomElement() else { return }

            let scale = UIScreen.main.scale
            let screenPx = CGSize(width: UIScreen.main.bounds.width * scale,
                                  height: UIScreen.main.bounds.height * scale)
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact

            self.teaserAssetID = chosen.localIdentifier
            self.imageManager.requestImage(for: chosen, targetSize: screenPx,
                                           contentMode: .aspectFill, options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, let image else { return }
                Task { @MainActor in
                    guard case .loading = self.state else { return }
                    self.teaserImage = image
                }
            }
        }
    }

    // MARK: - Scoring (off the main thread, throttled)

    /// `onBatch` fires once, on the main actor, as soon as `batchThreshold` photos have been scored
    /// (or all of them, if there are fewer). It carries the partial score map so the loading screen
    /// can pick + show an AI teaser EARLY, without waiting for every photo to finish scoring. The
    /// final `completion` still fires once everything is scored.
    private func scoreAll(_ assets: [PHAsset],
                          batchThreshold: Int = 12,
                          onBatch: @escaping ([String: PhotoScore]) -> Void = { _ in },
                          completion: @escaping ([String: PhotoScore]) -> Void) {
        guard !assets.isEmpty else { onBatch([:]); completion([:]); return }

        var scores: [String: PhotoScore] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 4)
        var batchFired = false
        let batchTarget = min(batchThreshold, assets.count)

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        DispatchQueue.global(qos: .userInitiated).async {
            for asset in assets {
                group.enter()
                semaphore.wait()
                self.imageManager.requestImage(for: asset,
                                                targetSize: CGSize(width: 320, height: 320),
                                                contentMode: .aspectFit,
                                                options: options) { image, _ in
                    let record: (PhotoScore) -> Void = { score in
                        lock.lock()
                        scores[asset.localIdentifier] = score
                        let fireBatch = !batchFired && scores.count >= batchTarget
                        if fireBatch { batchFired = true }
                        let snapshot = fireBatch ? scores : nil
                        lock.unlock()
                        if let snapshot { Task { @MainActor in onBatch(snapshot) } }
                        semaphore.signal(); group.leave()
                    }
                    guard let image else {
                        record(PhotoScore(
                            score: asset.mediaSubtypes.contains(.photoScreenshot) ? 0 : 0.5,
                            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                            reason: nil))
                        return
                    }
                    PhotoScorer.score(asset: asset, image: image) { score in record(score) }
                }
            }
            group.notify(queue: .main) {
                if !batchFired { onBatch(scores) }
                completion(scores)
            }
        }
    }

    /// Resolve liked photos (stored as local identifiers) back into assets,
    /// newest first. Stays entirely local; never touches the system Favorites album.
    func likedAssets() -> [PHAsset] {
        let ids = Array(PreferenceStore.shared.likedIDs)
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    // MARK: - Image loading for the UI

    /// Loads an image for display. `.opportunistic` may call back more than once: a fast,
    /// low-res degraded thumbnail first, then the crisp high-quality result. We forward EVERY
    /// delivery so the view upgrades from the placeholder to the final image and never stays
    /// on the blurry degraded thumbnail. `.exact` matches the requested target size precisely
    /// (no .fast undersize), and iCloud originals are allowed so full resolution can arrive.
    func requestImage(for asset: PHAsset, targetSize: CGSize, highQuality: Bool = false, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        // High quality = a single crisp delivery (no low-res degraded placeholder), used for the
        // peek + full-screen photos so they never sit blurry. Opportunistic (fast degraded then
        // upgrade) stays the default for the small tiles / scrubber previews.
        options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        imageManager.requestImage(for: asset, targetSize: targetSize,
                                  contentMode: .aspectFill, options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            // Forward the degraded thumbnail (instant placeholder) AND the later crisp result.
            // Dropping the degraded one would blank the view until the full image resolves;
            // dropping a non-degraded one would leave it blurry. We deliver both, in order.
            _ = isDegraded
            completion(image)
        }
    }
}
