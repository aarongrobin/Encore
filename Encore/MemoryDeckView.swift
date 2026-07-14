import SwiftUI
import Photos
import UIKit

enum MemoryViewMode { case deck, gallery }

enum DeckItem: Identifiable {
    case home
    case event(MemoryEvent, String)
    case photo(MemoryPhoto, MomentCaption)
    case end

    var id: String {
        switch self {
        case .home:            return "home"
        case .event(let e, _): return "e-" + e.id
        case .photo(let p, _): return "p-" + p.id
        case .end:             return "end"
        }
    }
}

/// A scrubbable stop = one Moment (a cluster of photos). Home/end are bookends
/// (year == nil) and are excluded from the scrub range.
struct Burst: Identifiable {
    let id: String
    let label: String       // "2019"
    let year: Int?
    let firstItemID: String
    let isYearStart: Bool
    var heroAsset: PHAsset? = nil   // best/scored photo of the Moment
    var firstAsset: PHAsset? = nil  // chronological FIRST photo — the preview's front
    var peekAssets: [PHAsset] = []  // up to 3 for the peeking stack
    var photoCount: Int = 0
    var subtitle: String = ""       // "Jul 12 · 3:40 PM"
}

private enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// "v1.0 (7)" — shown subtly so we can confirm which build is actually running.
func appVersionString() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "v\(v) (\(b))"
}

/// Caption for a photo identified only by its year (used by the tap-to-share galleries).
func momentCaption(forYear year: Int) -> MomentCaption {
    let cal = Calendar.current
    let yearsAgo = cal.component(.year, from: Date()) - year
    let yearsText = yearsAgo == 1 ? "1 year ago today" : "\(yearsAgo) years ago today"
    var comps = DateComponents()
    comps.year = year
    comps.month = cal.component(.month, from: Date())
    comps.day = cal.component(.day, from: Date())
    let date = cal.date(from: comps) ?? Date()
    let formatter = DateFormatter(); formatter.dateFormat = "MMMM d, yyyy"
    return MomentCaption(yearsAgoText: yearsText, dateText: formatter.string(from: date), placeText: nil)
}

/// Reports the global-space bottom edge of the home date block so the home mosaic can inset beneath
/// it with a real measurement instead of a magic constant (see `homeMosaicTopInset`). Using the
/// global frame works because the mosaic page ignores the safe area, so its top is at global y=0 —
/// the date block's global maxY is exactly the inset the mosaic needs.
private struct HomeDateBlockBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MemoryDeckView: View {
    let memories: [YearMemory]
    @ObservedObject var service: PhotoLibraryService
    @Binding var mode: MemoryViewMode
    let hiddenCount: Int
    let onReviewHidden: () -> Void

    @State private var items: [DeckItem] = []
    @State private var bursts: [Burst] = []
    @State private var indexByID: [String: Int] = [:]
    @State private var currentID: String?
    @State private var sharePicker = false
    @State private var badgeCleared = false
    /// True once the staged home entrance (mosaic fade + peek pop-up) has played once this session.
    /// Lives in the stable parent, not in the recyclable `DeckHomePage`, so a FAR return to home
    /// (the home page was discarded by the LazyVStack and is recreated fresh) lands at rest with the
    /// peek bobbing instead of replaying the entrance. The near return (home stayed realized) is
    /// handled separately by `DeckHomePage`'s `onChange(of: isCurrentHome)` → `resetToPeek()`.
    @State private var homeEntranceDone = false
    /// Drives the top chrome (controls + progress) AND the scrubber, based on the current page.
    /// Hidden on the home/end bookends, brought in by `updateChrome` when landing on a real photo.
    @State private var chromeVisible = false
    /// Cancels a pending deferred chrome reveal if we leave the page before it fires.
    @State private var chromeRevealWork: DispatchWorkItem?
    /// Delay before the chrome (controls + progress + scrubber) eases in when landing on a photo by
    /// paging (the first photo from home, or swiping back up from the end recap). Snappy.
    private let returnChromeDelay: Double = 0.15
    /// Measured top inset for the home mosaic: the global Y of the bottom of the home date block plus
    /// a gap, fed by `HomeDateBlockBottomKey`. The mosaic's first row always starts cleanly below the
    /// FULL date block (the persistent title row + serif date + invite subtitle), regardless of how
    /// long the "N years of memories" string runs or which device's safe-area inset we're on. This
    /// replaces the old fixed `.padding(.top, 172)`, which the added subtitle line overran and drew on
    /// top of the photos (build 47, MAR-46 follow-up). The default is a close fallback used only for
    /// the first layout pass, before the measurement lands (and any settle happens under the entrance
    /// fade, so it never reads as a jump).
    @State private var homeMosaicTopInset: CGFloat = 190

    // MARK: Derived

    private var currentIndex: Int { currentID.flatMap { indexByID[$0] } ?? 0 }
    private var currentBurstIndex: Int {
        var result = 0
        for (i, burst) in bursts.enumerated() {
            if let idx = indexByID[burst.firstItemID], idx <= currentIndex { result = i }
        }
        return result
    }
    private var progress: Double {
        guard items.count > 1 else { return 0 }
        return Double(currentIndex) / Double(items.count - 1)
    }

    /// Scrub stops: every real Moment, and ONLY real moments. The home + end bookends are
    /// deliberately excluded (build 39, MAR-37) so the timeline/menu spans just the actual
    /// photos — cleaner mental model, and it stops the "Top"/"Recap" cap cards from being scrub
    /// targets. Home/end are reached by swiping, not by the scrubber. The thumb can land on any
    /// moment; speed only changes what the overlay reveals.
    private var momentStops: [Int] {
        bursts.indices.filter { i in bursts[i].year != nil }
    }

    private var totalPhotos: Int { allVisible.count }
    private var photoPosition: Int {
        guard !items.isEmpty, currentIndex < items.count else { return 0 }
        return items[0...currentIndex].reduce(0) { acc, item in
            if case .photo = item { return acc + 1 } else { return acc }
        }
    }

    private var memorySignature: String {
        let base = memories.map { "\($0.id)|\($0.placeName ?? "")|\($0.visiblePhotos.count)" }.joined()
        // Per-moment places resolve asynchronously after the deck first builds; fold them into the
        // signature so the deck rebuilds (and the captions pick up the correct per-moment city) the
        // moment they arrive.
        let places = service.momentPlaces.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined()
        return base + "#" + places
    }

    // MARK: Summaries

    private var allVisible: [MemoryPhoto] { memories.flatMap { $0.visiblePhotos } }
    private var allMoments: [Moment] { memories.flatMap { $0.moments } }
    private var bestPhotoOverall: MemoryPhoto? { allVisible.max { $0.score.score < $1.score.score } }
    private var placeCount: Int { Set(memories.compactMap { $0.placeName }).count }
    private var dateLine: String {
        let f = DateFormatter(); f.dateFormat = "MMMM d"; return f.string(from: Date())
    }
    private var mosaicTiles: [(asset: PHAsset, year: Int)] {
        allMoments.prefix(12).compactMap { m in m.best.map { (asset: $0.asset, year: m.year) } }
    }
    private var firstPhoto: MemoryPhoto? {
        for memory in memories {
            for moment in memory.moments where moment.photos.first != nil {
                return moment.photos.first
            }
        }
        return bestPhotoOverall
    }

    /// The home cover's date block, rendered directly beneath the persistent "On this day" title row
    /// (which lives in the top chrome). Title above, date beneath: one well-set top block. The full
    /// weekday + month/day reads cleaner than the old bare "June 26". Only shown on home.
    private var homeDateBlock: some View {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        let yc = memories.count
        return VStack(alignment: .leading, spacing: 3) {
            Text(f.string(from: Date()))
                .font(.system(size: 30, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("\(yc) \(yc == 1 ? "year" : "years") of memories, waiting")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        page(for: item)
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .ignoresSafeArea()

            // Persistent top chrome. The title + gallery + menu row is the SAME parent-owned element
            // on every page (home and every photo), so it can never jump position between screens —
            // it is laid out once at the safe-area top and just stays there. Only what sits BENEATH
            // the row changes: the home date block on home, the progress track on photos. The row
            // itself never moves. (Build 46, MAR-46: this replaces the old setup where the home cover
            // drew its own bar at a different Y, which made the controls jump on the first swipe.)
            VStack(alignment: .leading, spacing: 0) {
                MemoryControlsBar(mode: $mode, service: service,
                                  hiddenCount: hiddenCount, onReviewHidden: onReviewHidden,
                                  dark: true)
                    // Hidden only on the end recap (it has its own layout). Pure opacity — never a move.
                    .opacity(currentID == "end" ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: currentID)
                    // opacity 0 alone still hit-tests in SwiftUI, so the invisible bar would catch
                    // taps over the recap — gate hit-testing to when it's actually shown.
                    .allowsHitTesting(currentID != "end")

                // Home-only date block: the row's "On this day" title sits above it, the date and
                // invite copy beneath — one clean top block. It pages away with home as the first
                // photo comes in; the title row above it stays put.
                if currentID == "home" {
                    homeDateBlock
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        // Report the block's bottom edge so the mosaic insets beneath it by measurement,
                        // not by a constant — the subtitle line can never overlap the photos again.
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: HomeDateBlockBottomKey.self,
                                                       value: proxy.frame(in: .global).maxY)
                            }
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false) // purely decorative — don't swallow taps on the mosaic
                }

                ProgressTrack(progress: progress, position: photoPosition, total: totalPhotos)
                    .padding(.top, 16)
                    .opacity(chromeVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.28), value: chromeVisible)
                    // Laid out (and faintly hittable) even when hidden on home — gate hit-testing too.
                    .allowsHitTesting(chromeVisible)
            }

            if chromeVisible && momentStops.count >= 2 {
                BurstScrubber(bursts: bursts,
                              stops: momentStops,
                              currentBurstIndex: currentBurstIndex,
                              service: service) { idx in jump(to: idx) }
                    .transition(.opacity)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: memorySignature) { _, _ in rebuild() }
        .onChange(of: currentID) { old, new in
            // Any scroll away from the opening page counts as an interaction.
            if old != nil, new != old { clearBadgeOnce() }
            updateChrome(for: new)
        }
        .onPreferenceChange(HomeDateBlockBottomKey.self) { bottom in
            // Keep the last good measurement when home is off-screen (the preference reverts to 0 once
            // the date block is no longer in the tree), so the realized home page never flashes to a
            // wrong inset on the way back.
            if bottom > 0 { homeMosaicTopInset = bottom + 20 }
        }
        .sheet(isPresented: $sharePicker) {
            MomentSharePicker(moments: allMoments, service: service)
        }
    }

    /// Show/hide the top chrome + scrubber based on the current page. Landing on a bookend
    /// (home/end) hides it at once. Landing on a real photo by paging brings it in promptly.
    private func updateChrome(for id: String?) {
        chromeRevealWork?.cancel()
        let onBookendNow = id == "home" || id == "end" || id == nil
        if onBookendNow {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = false }
            return
        }
        guard !chromeVisible else { return }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = true }
        }
        chromeRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + returnChromeDelay, execute: work)
    }

    /// Clear the notification badge the first time the user interacts with the deck.
    private func clearBadgeOnce() {
        guard !badgeCleared else { return }
        badgeCleared = true
        NotificationManager.shared.clearBadge()
    }

    // MARK: Build + navigation

    private func rebuild() {
        var newItems: [DeckItem] = [.home]
        var newBursts: [Burst] = [Burst(id: "home", label: "Today", year: nil, firstItemID: "home", isYearStart: false)]

        for memory in memories {
            for event in memory.events { newItems.append(.event(event, memory.headline)) }

            // One scrub stop per Moment, carrying its preview data.
            for (mi, moment) in memory.moments.enumerated() {
                // Each moment uses ITS OWN resolved city (momentPlaces), falling back to the
                // year-level place only when the moment has no coordinate. This is what fixes the
                // wrong-city bug: a photo taken elsewhere that day no longer inherits the year's
                // first-photo city.
                let caption = MomentCaption(yearsAgoText: memory.headline,
                                            dateText: memory.fullDateString,
                                            placeText: service.momentPlaces[moment.id] ?? memory.placeName)
                let cStart = newItems.count
                for photo in moment.photos { newItems.append(.photo(photo, caption)) }
                guard newItems.count > cStart else { continue }
                newBursts.append(Burst(id: moment.id,
                                       label: "\(memory.year)",
                                       year: memory.year,
                                       firstItemID: newItems[cStart].id,
                                       isYearStart: mi == 0,
                                       heroAsset: (moment.best ?? moment.photos.first)?.asset,
                                       firstAsset: moment.photos.first?.asset,
                                       peekAssets: moment.photos.prefix(3).map { $0.asset },
                                       photoCount: moment.photos.count,
                                       subtitle: Self.momentSubtitle(moment)))
            }
        }

        newItems.append(.end)
        newBursts.append(Burst(id: "end", label: "Recap", year: nil, firstItemID: "end", isYearStart: false))

        items = newItems
        bursts = newBursts
        // uniquingKeysWith (never traps) — belt-and-suspenders against any duplicate item IDs.
        indexByID = Dictionary(newItems.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        if currentID == nil { currentID = "home" }
    }

    private func jump(to burstIndex: Int) {
        guard bursts.indices.contains(burstIndex) else { return }
        jump(toID: bursts[burstIndex].firstItemID, animated: false)
    }

    private func jump(toID targetID: String, animated: Bool) {
        if let idx = indexByID[targetID], idx < items.count, case .photo(let p, _) = items[idx] {
            service.prioritize([p.asset])
        }
        if animated {
            withAnimation(.snappy(duration: 0.3)) { currentID = targetID }
        } else {
            currentID = targetID
        }
    }

    @ViewBuilder
    private func page(for item: DeckItem) -> some View {
        switch item {
        case .home:
            DeckHomePage(dateLine: dateLine,
                         yearCount: memories.count,
                         tiles: mosaicTiles,
                         firstAsset: firstPhoto?.asset,
                         topInset: homeMosaicTopInset,
                         service: service,
                         mode: $mode,
                         hiddenCount: hiddenCount,
                         onReviewHidden: onReviewHidden,
                         onInteract: { clearBadgeOnce() },
                         // A tap on the peek affordance advances to the first photo with a normal
                         // animated scroll. Swipes are native paging, owned by the outer ScrollView.
                         onAdvance: { jump(toID: firstPhoto.map { "p-" + $0.id } ?? "end", animated: true) },
                         homeEntranceDone: $homeEntranceDone,
                         isCurrentHome: currentID == "home")
        case .event(let event, let yearsAgo):
            EventPageView(event: event, yearsAgoText: yearsAgo)
        case .photo(let photo, let caption):
            MemoryPageView(photo: photo, caption: caption, service: service)
        case .end:
            DeckEndPage(tiles: mosaicTiles,
                        dateLine: dateLine,
                        yearCount: memories.count,
                        onShareMemory: { sharePicker = true },
                        onBackToStart: { jump(toID: "home", animated: false) },
                        service: service)
        }
    }

    static func statLine(photos: Int, years: Int, places: Int) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) \(photos == 1 ? "photo" : "photos")") }
        if years > 0 { parts.append("\(years) \(years == 1 ? "year" : "years")") }
        if places > 0 { parts.append("\(places) \(places == 1 ? "place" : "places")") }
        return parts.joined(separator: "  ·  ")
    }

    /// "Jul 12 · 3:40 PM" for a Moment's hero, used in the scrubber preview.
    static func momentSubtitle(_ moment: Moment) -> String {
        guard let date = (moment.best ?? moment.photos.first)?.asset.creationDate else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Photo page (full-bleed, immersive)

private struct MemoryPageView: View {
    let photo: MemoryPhoto
    let caption: MomentCaption
    let service: PhotoLibraryService

    @State private var uiImage: UIImage?
    @State private var faded = false
    @State private var showShare = false
    @State private var liked = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                        .opacity(faded ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: faded)
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                captionOverlay
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // Tapping the photo opens the SAME share UI used everywhere else (PhotoShareView with
            // THIS photo's asset), not a separate preview, so the experience is consistent across
            // the home mosaic, the recap tiles, and the immersive deck (build 33).
            .onTapGesture { showShare = true }
        }
        .onAppear {
            liked = PreferenceStore.shared.isLiked(photo.id)
            // First-photo handoff: when this page IS the home peek hero, the identical image is
            // already decoded (loading-screen prefetch, the same one the peek card showed). Seed it
            // immediately — no request, no spinner, no fade — so the swipe-up reveal hands off into
            // this page with zero reload. The peek and this page use the same screen-res image with
            // the same top-aligned fill crop, so the swap is imperceptible: one continuous motion.
            if uiImage == nil,
               service.peekHeroAssetID == photo.asset.localIdentifier,
               let hero = service.peekHeroImage {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { uiImage = hero; faded = true }
                return
            }
            // Full-screen immersive photo: load at SCREEN resolution with a single high-quality
            // delivery so it comes up crisp, not blurry (maximum size + opportunistic was slow to
            // sharpen on large iCloud photos).
            let screenPx = CGSize(width: UIScreen.main.bounds.width * UIScreen.main.scale,
                                  height: UIScreen.main.bounds.height * UIScreen.main.scale)
            service.requestImage(for: photo.asset,
                                 targetSize: screenPx, highQuality: true) { img in
                guard let img else { return }
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { uiImage = img }
                if !faded { faded = true }
            }
        }
        .sheet(isPresented: $showShare) {
            PhotoShareView(asset: photo.asset, caption: caption, service: service)
        }
    }

    private var captionOverlay: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption.yearsAgoText)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                Text(caption.dateText).font(.subheadline)
                if let place = caption.placeText {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(place)
                    }
                    .font(.subheadline)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    liked = PreferenceStore.shared.toggleLiked(photo.id)
                    Haptics.selection()
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(liked ? Color.accentColor : .white)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .symbolEffect(.bounce, value: liked)

                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 54)
    }
}

// MARK: - Event page

private struct EventPageView: View {
    let event: MemoryEvent
    let yearsAgoText: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.92), .black],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: event.icon).font(.system(size: 60)).foregroundStyle(.white)
                    Text(yearsAgoText)
                        .font(.system(.title, design: .serif).weight(.semibold)).foregroundStyle(.white)
                    Text(event.title).font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
                    if let location = event.location, !location.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                            Text(location)
                        }
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(40)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Home cover (recap-style bookend: title, mosaic, photo inviting a pull-up)

private struct DeckHomePage: View {
    let dateLine: String
    let yearCount: Int
    let tiles: [(asset: PHAsset, year: Int)]
    let firstAsset: PHAsset?
    /// Top inset for the mosaic, measured by the parent from the live home date block so the grid's
    /// first row always clears the title row + serif date + invite subtitle (no magic constant).
    let topInset: CGFloat
    let service: PhotoLibraryService
    let mode: Binding<MemoryViewMode>
    let hiddenCount: Int
    let onReviewHidden: () -> Void
    let onInteract: () -> Void
    /// Tap on the peek affordance: advance to the first photo with a normal animated scroll.
    let onAdvance: () -> Void
    /// Lives in the stable parent. True once the staged entrance has played once this session, so a
    /// FAR return (this page recreated fresh by the LazyVStack) lands at rest with no replay.
    @Binding var homeEntranceDone: Bool
    /// True when home is the deck's current page (parent passes `currentID == "home"`). The home
    /// page lives in a LazyVStack and can stay realized across a return, so onAppear is not
    /// guaranteed to re-fire; observing this resets the card to its peek/bob state on every return.
    let isCurrentHome: Bool

    /// Automatic idle drift. Toggles between two `idleOffset` endpoints under a repeatForever
    /// ease so the peeking photo gently rises and settles ON ITS OWN as a "swipe me up" hint.
    /// This drives its own dedicated `.offset(y:)` transform layer, fully decoupled from the
    /// entrance and rest offsets so the transforms never share a value or fight an animation.
    @State private var idleLifted = false
    /// One-shot entrance: header + mosaic ease in on appear.
    @State private var entered = false
    /// Staged entrance, the final beat: after the header + mosaic are in, the peek card
    /// springs up from below the bottom edge into its resting peek slice, THEN the idle bob
    /// arms. False = card parked below the screen; true = card at its resting peek position.
    @State private var peekEntered = false
    @State private var shareSelection: ShareSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    /// True once the peek card has finished its entrance and is at its resting slice. This is the
    /// single condition that arms/disarms the idle drift (see the `onChange(of: isIdle)` owner).
    private var isIdle: Bool { peekEntered }

    // MARK: Tunable feel constants
    /// Height of the photo slice that peeks above the bottom edge at rest. The photo is
    /// top-aligned, so its TOP is always visible.
    private let peekHeight: CGFloat = 184
    /// Idle drift travel (points) — the peeking photo automatically rises by this much and
    /// settles back, continuously. Negative = up. Tuned for a calm, clearly-visible motion.
    private let idleTravel: CGFloat = 15
    /// Calm period for one half of the idle rise/settle cycle.
    private let idleDuration: Double = 1.5

    var body: some View {
        GeometryReader { geo in
            // The peek photo is laid out at full screen height and pushed DOWN by `restPush` so
            // only its top `peekHeight` slice shows above the bottom edge. This is a static rest
            // position: the home→first-photo move is native paging (the outer ScrollView slides this
            // whole page away with the same physics as photo → photo), so there is no reveal
            // transform driving the photo up.
            let restPush = geo.size.height - peekHeight
            // The idle drift is keyed SOLELY on `idleLifted`, the single source the repeatForever
            // animation observes. It re-arms via the isIdle owner (see onChange below) so the
            // autoreversing loop restarts cleanly every time the page returns to idle.
            let idleOffset: CGFloat = idleLifted ? -idleTravel : 0
            // Staged entrance: until the peek has entered, park the card fully below its rest slice
            // so it sits off-screen, then spring to 0 (its resting peek). This is its own transform
            // layer so it never shares a value with the idle transform.
            let entranceOffset: CGFloat = peekEntered ? 0 : (peekHeight + 24)

            ZStack(alignment: .bottom) {
                Color.black

                VStack(spacing: 20) {
                    // No header lives on this page anymore. The title + date + menu/gallery are the
                    // parent-owned persistent top chrome, overlaid above this page, so the mosaic just
                    // clears it with a fixed top inset.
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(tiles.prefix(12).enumerated()), id: \.element.asset.localIdentifier) { idx, tile in
                            Button {
                                onInteract()
                                shareSelection = ShareSelection(asset: tile.asset, caption: momentCaption(forYear: tile.year))
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        // Small mosaic tile: ~1/3-width on screen. Request at its
                                        // display size (AsyncPHImage scales to native pixels), so
                                        // it is crisp without wasting memory on full-res thumbs.
                                        AsyncPHImage(asset: tile.asset, service: service,
                                                     targetSize: CGSize(width: 140, height: 140))
                                    }
                                    .overlay {
                                        LinearGradient(colors: [.clear, .black.opacity(0.35)],
                                                       startPoint: .center, endPoint: .bottom)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text(String(tile.year))
                                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.35), in: Capsule())
                                            .padding(5)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .opacity(entered ? 1 : 0)
                            .animation(.easeOut(duration: 0.4).delay(Double(idx) * 0.035 + 0.1),
                                       value: entered)
                        }
                    }
                    .padding(.horizontal, 16)
                    // Measured by the parent from the live date block (title row + serif date + invite
                    // copy). Layout-driven, so a longer "N years of memories" string or a different
                    // safe-area inset can never push the subtitle onto the photos again.
                    .padding(.top, topInset)

                    Spacer(minLength: 0)
                }
                .padding(.bottom, peekHeight + 10)
                .opacity(entered ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: entered)

                // The peeking photo — the visual swipe-up affordance and the home's resting card.
                // It owns no gesture: a swipe anywhere on the page is native paging (the outer
                // ScrollView pages home → first photo with the same physics as photo → photo), and a
                // tap on the card advances via `onAdvance`. Laid out at full height and parked at its
                // peek slice by the offsets below.
                peekPhoto(width: geo.size.width, height: geo.size.height)
                    // Staged-entrance transform: the card springs up from below the bottom edge
                    // into its resting peek slice as the final beat of the home open. Its own
                    // layer + its own spring, keyed solely on `peekEntered`, so it can't fight
                    // the idle drift (which only arms after the entrance, via the isIdle gate).
                    .offset(y: entranceOffset)
                    .animation(.interpolatingSpring(stiffness: 200, damping: 26), value: peekEntered)
                    // Dedicated idle-drift transform: its ONLY animation is the repeatForever
                    // ease, keyed solely on `idleLifted`, so nothing else can interrupt it.
                    .offset(y: idleOffset)
                    .animation(.easeInOut(duration: idleDuration).repeatForever(autoreverses: true),
                               value: idleLifted)
                    // Static rest push: parks the card so only its top peek slice shows. No reveal
                    // transform — the page itself scrolls away under native paging.
                    .offset(y: restPush)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                Text(appVersionString())
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.trailing, 14).padding(.bottom, 8)
            }
        }
        .onChange(of: isIdle) { _, idle in
            // SINGLE owner of arming `idleLifted`. Whenever the peek card reaches its resting slice
            // (after the entrance, or on return to home), disarm then re-arm on the next runloop so
            // the repeatForever ease restarts cleanly from rest rather than snapping to an endpoint
            // and freezing. While not idle, settle to rest (0).
            if idle {
                idleLifted = false
                DispatchQueue.main.async { if isIdle { idleLifted = true } }
            } else {
                idleLifted = false
            }
        }
        .onChange(of: isCurrentHome) { _, nowHome in
            // The home page lives in a LazyVStack and may stay realized after the deck pages off it,
            // so scrolling back to home does not reliably re-fire onAppear. When the deck pages back
            // onto home (native swipe-down, scrub-to-top, "Back to the start"), reset the card to
            // its resting peek + bob.
            if nowHome { resetToPeek() }
        }
        .onAppear {
            // FAR return: the home page was discarded by the LazyVStack while the user was deep in
            // the deck and is now recreated fresh ("Back to the start", scrub-to-top). isCurrentHome
            // is already true, so onChange(of:) never fires — only this onAppear runs. Land the cover
            // at rest with NO replay: mosaic present and peek card at its slice, both set inside a
            // disablesAnimations transaction so the fade + spring don't play. The idle bob arms via
            // the isIdle owner (peekEntered false→true).
            if homeEntranceDone {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) {
                    entered = true
                    peekEntered = true
                }
                return
            }
            // First realized appear this session: play the staged entrance exactly once. Header +
            // mosaic ease in (`entered`), then as the final beat the peek card springs up from below
            // the bottom edge into its resting slice (`peekEntered`), which arms the idle bob via the
            // isIdle gate. The hero is preloaded, so when the card pops up it already shows the photo.
            homeEntranceDone = true
            entered = true
            if !peekEntered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard !peekEntered else { return }
                    peekEntered = true
                }
            }
        }
        .sheet(item: $shareSelection) { sel in
            PhotoShareView(asset: sel.asset, caption: sel.caption, service: service)
        }
    }

    /// THE single reset. Whenever home becomes the current page again (fresh launch, native
    /// swipe-down, scrub-to-top, relaunch) this returns the card to its resting peek and re-arms
    /// the idle drift (disarm now, arm next runloop) so the autoreversing bob restarts cleanly.
    private func resetToPeek() {
        idleLifted = false
        // Returns to home do NOT replay the pop-up entrance — the card belongs at its resting peek
        // with the photo present and bobbing immediately. Only the first appear stages the pop-up.
        peekEntered = true
        DispatchQueue.main.async { if isIdle { idleLifted = true } }
    }

    // MARK: Peek — the first photo peeking up with its affordance overlaid

    /// The first photo, pinned to the bottom and top-aligned so its TOP edge always shows.
    /// The grabber pill + "Swipe up to begin" label sit OVER the photo (on a subtle bottom
    /// scrim for legibility) — there is no black band above the picture. This view is the visual
    /// swipe-up affordance and the home's resting card; swiping up pages it away natively.
    private func peekPhoto(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Group {
                if let firstAsset {
                    // The peek photo is laid out at FULL SCREEN size. Load it at SCREEN resolution
                    // (.zero) with a single high-quality delivery so it is crisp and never shows the
                    // blurry low-res placeholder (requesting the full original at maximum size with
                    // opportunistic delivery was what left it blurry).
                    //
                    // The hero is prefetched + decoded on the loading screen, so when its identifier
                    // matches we hand the already-decoded image straight in and the home appears with
                    // the photo on screen — no white, no async pop-in. (`preloaded` makes AsyncPHImage
                    // skip the request; if the prefetch fell back, this is nil and it loads normally.)
                    AsyncPHImage(asset: firstAsset, service: service,
                                 targetSize: .zero,
                                 alignment: .top,
                                 highQuality: true,
                                 preloaded: service.peekHeroAssetID == firstAsset.localIdentifier
                                     ? service.peekHeroImage : nil)
                        // Key to the asset so the peek rebuilds (and reloads) if the first photo
                        // changes while home stays realized (e.g. after connect-calendar / unhide),
                        // instead of holding a stale preloaded image.
                        .id(firstAsset.localIdentifier)
                } else {
                    LinearGradient(colors: [Color.accentColor, .black],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .clipped()

            // Affordance overlaid on the photo's TOP slice, on a soft scrim for legibility.
            VStack(spacing: 10) {
                Capsule().fill(.white.opacity(0.95)).frame(width: 42, height: 5)
                HStack(spacing: 7) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .bold))
                    Text("Swipe up to begin")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            )
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: 28,
                                          style: .continuous))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 28,
                                   style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.5), radius: 22, y: -8)
        .contentShape(Rectangle())
        // A tap on the obvious affordance advances to the first photo with a normal animated
        // scroll. Swipes are owned by the outer paging ScrollView (native paging), so a swipe up
        // anywhere on home pages to the first photo with the same physics as photo → photo.
        .onTapGesture {
            onInteract()
            onAdvance()
        }
    }
}

// MARK: - End-of-day summary

private struct DeckEndPage: View {
    let tiles: [(asset: PHAsset, year: Int)]
    let dateLine: String
    let yearCount: Int
    let onShareMemory: () -> Void
    let onBackToStart: () -> Void
    let service: PhotoLibraryService

    @State private var logCount = 0
    @State private var didAppear = false
    @State private var shareSelection: ShareSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ZStack {
            Color.black
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 4) {
                        Text("That was \(dateLine)")
                            .font(.system(.title, design: .serif).weight(.semibold))
                            .foregroundStyle(.white)
                        Text("across \(yearCount) \(yearCount == 1 ? "year" : "years") of memories")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 60)

                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(tiles.prefix(12), id: \.asset.localIdentifier) { tile in
                            Button { shareSelection = ShareSelection(asset: tile.asset, caption: momentCaption(forYear: tile.year)) } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        AsyncPHImage(asset: tile.asset, service: service,
                                                     targetSize: CGSize(width: 140, height: 140))
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text(String(tile.year))
                                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.4), in: Capsule())
                                            .padding(5)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    if logCount > 0 {
                        Text("You've looked back on \(logCount) \(logCount == 1 ? "day" : "days").")
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Button(action: onShareMemory) {
                        Label("Share a memory", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 24)

                    Button(action: onBackToStart) {
                        Label("Back to the start", systemImage: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.bottom, 44)
                }
            }
        }
        .onAppear {
            if !didAppear {
                didAppear = true
                PreferenceStore.shared.recordDayCompleted()
                logCount = PreferenceStore.shared.dayLogCount
                Haptics.success()
            }
        }
        .sheet(item: $shareSelection) { sel in
            PhotoShareView(asset: sel.asset, caption: sel.caption, service: service)
        }
    }
}

// MARK: - Moment scrubber
// One stop set = the real Moments only (home/end bookends excluded as of build 39). The track
// always shows year ticks + burst sublines. Speed only gates the OVERLAY: fast = year only,
// slow = year + the burst preview.

private struct BurstScrubber: View {
    let bursts: [Burst]
    let stops: [Int]         // every real Moment (no home/end caps) — the single stop set
    let currentBurstIndex: Int
    let service: PhotoLibraryService
    let onScrub: (Int) -> Void

    @GestureState private var dragging = false
    @State private var anchorPos: CGFloat?     // continuous stop-axis position at grab
    @State private var revealBursts = false    // true once the user slows down
    @State private var samples: [(y: CGFloat, t: Date)] = []  // recent drag samples for smoothing
    @State private var previewIndex: Int?

    private let inset: CGFloat = 96

    // MARK: Burst-reveal threshold (tune on device)
    /// Smoothed drag speed (points/sec) at/below which the burst preview reveals.
    /// Above it, only the year overlay shows. The two-value gap is the hysteresis
    /// band that stops the overlay from flickering between year and year+bursts.
    private let burstRevealSpeed: CGFloat = 120
    private let burstHideSpeed: CGFloat = 380
    /// How many recent drag samples we average the velocity over.
    private let velocityWindow = 5

    private var maxPos: CGFloat { CGFloat(max(stops.count - 1, 1)) }

    /// Position of a stop on the [0...1] axis (its ordinal within the stop set).
    private func axis(of burstIndex: Int) -> CGFloat {
        guard let i = stops.firstIndex(of: burstIndex) else { return 0 }
        return CGFloat(i) / maxPos
    }

    /// Where the thumb and preview both read from: the live snap target while dragging,
    /// the committed page when idle. They can never diverge because they share this.
    private var displayIndex: Int { (dragging ? previewIndex : nil) ?? currentBurstIndex }

    /// Rolling-average finger speed (points/sec) over the recent samples.
    private func smoothedSpeed() -> CGFloat {
        guard samples.count >= 2 else { return 0 }
        let dy = abs(samples.last!.y - samples.first!.y)
        let dt = max(samples.last!.t.timeIntervalSince(samples.first!.t), 1.0 / 120)
        return dy / CGFloat(dt)
    }

    private func yFor(_ burstIndex: Int, _ trackHeight: CGFloat) -> CGFloat {
        inset + axis(of: burstIndex) * trackHeight
    }

    /// Snap a continuous stop-axis position (0...maxPos) to the nearest stop index.
    private func snap(_ posFloat: CGFloat) -> Int {
        guard !stops.isEmpty else { return 0 }
        let clamped = Int(posFloat.rounded())
        return stops[min(max(clamped, 0), stops.count - 1)]
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(geo.size.height - inset * 2, 1)
            let railX = geo.size.width - 14
            // ONE consistent pitch over the single stop set.
            let stopPitch = trackHeight / maxPos
            let thumbY = yFor(displayIndex, trackHeight)

            ZStack {
                // Year overlay — always shown while dragging; bursts add on when slowed.
                if dragging, bursts.indices.contains(displayIndex) {
                    MomentPreviewStack(burst: bursts[displayIndex], service: service,
                                       showMoment: revealBursts, bigYearOnly: !revealBursts)
                        .position(x: railX - 24 - 75,
                                  y: min(max(thumbY, 130), geo.size.height - 130))
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                // Continuous connecting rail behind the ticks.
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: 2, height: trackHeight)
                    .position(x: railX, y: inset + trackHeight / 2)
                    .allowsHitTesting(false)

                // Year tick marks — longer/bolder, with the year number — ALWAYS visible.
                ForEach(stops, id: \.self) { bi in
                    if bursts[bi].isYearStart, let y = bursts[bi].year {
                        let isCurrent = bi == displayIndex
                        Text(verbatim: "\(y)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.7))
                            .position(x: railX - 22, y: yFor(bi, trackHeight))
                            .allowsHitTesting(false)
                    }
                }

                // Both tiers of ticks — ALWAYS rendered, even at rest:
                //   year boundaries get a long/bold tick, every other burst a short subline.
                ForEach(stops, id: \.self) { bi in
                    let isCurrent = bi == displayIndex
                    let isYear = bursts[bi].isYearStart || bursts[bi].year == nil
                    Capsule()
                        .fill(isCurrent ? Color.accentColor
                              : (isYear ? .white.opacity(0.75) : .white.opacity(0.4)))
                        .frame(width: isCurrent ? 18 : (isYear ? 13 : 7),
                               height: isCurrent ? 4 : (isYear ? 3 : 2))
                        .position(x: railX, y: yFor(bi, trackHeight))
                }
                .opacity(dragging ? 1 : 0.8)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .allowsHitTesting(false)

                // Coral thumb at the current position.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .position(x: railX, y: thumbY)
                    .allowsHitTesting(false)

                // Catcher — band AT the thumb, so far touches pass through to paging.
                Color.clear
                    .frame(width: 40, height: 160)
                    .contentShape(Rectangle())
                    .position(x: railX, y: thumbY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { value in
                                if anchorPos == nil {
                                    anchorPos = axis(of: currentBurstIndex) * maxPos
                                    samples = [(value.location.y, Date())]
                                    revealBursts = false
                                }
                                guard let anchor = anchorPos else { return }

                                // Keep a short rolling window of samples to smooth velocity.
                                samples.append((value.location.y, Date()))
                                if samples.count > velocityWindow { samples.removeFirst() }

                                // Smoothed speed gates ONLY the overlay reveal, with a
                                // hysteresis band so a single frame can't flip it.
                                let speed = smoothedSpeed()
                                if !revealBursts, speed <= burstRevealSpeed { revealBursts = true }
                                else if revealBursts, speed >= burstHideSpeed { revealBursts = false }

                                let deltaY = value.location.y - value.startLocation.y
                                let posFloat = min(max(anchor + deltaY / stopPitch, 0), maxPos)
                                let target = snap(posFloat)
                                if target != displayIndex {
                                    previewIndex = target
                                    Haptics.selection()
                                    onScrub(target)
                                } else {
                                    previewIndex = target
                                }
                            }
                    )
            }
            .coordinateSpace(name: "scrubber")
            .animation(.snappy(duration: 0.18), value: dragging)
            .animation(.snappy(duration: 0.2), value: revealBursts)
            .onChange(of: dragging) { _, isDragging in
                if !isDragging {
                    anchorPos = nil; previewIndex = nil
                    samples = []; revealBursts = false
                }
            }
        }
    }
}

/// A peeking stack of a Moment's photos (hero on top) shown while scrubbing.
private struct MomentPreviewStack: View {
    let burst: Burst
    let service: PhotoLibraryService
    var showMoment = false
    /// When true the user is scrubbing fast: show only the big YEAR overlay, no bursts.
    var bigYearOnly = false

    private let cardW: CGFloat = 150
    private let cardH: CGFloat = 196

    /// Home/end caps carry no photos — show a small graceful card instead of blanking.
    private var isBookend: Bool { burst.year == nil }

    var body: some View {
        if isBookend {
            bookendCard
        } else if bigYearOnly {
            yearOnlyCard
        } else {
            momentStack
        }
    }

    /// Compact "which year am I in" overlay shown while scrubbing fast.
    private var yearOnlyCard: some View {
        Text(burst.label)
            .font(.system(size: 54, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private var bookendCard: some View {
        let isTop = burst.id == "home"
        return VStack(spacing: 8) {
            Image(systemName: isTop ? "arrow.up.to.line" : "sparkles")
                .font(.system(size: 26, weight: .semibold))
            Text(isTop ? "Top" : "Recap")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text(isTop ? "Back to today" : "End of the day")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .frame(width: cardW, height: cardH)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.85), .black],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private var momentStack: some View {
        ZStack(alignment: .topLeading) {
            // Peek cards behind (drawn back-to-front).
            ForEach(Array(burst.peekAssets.dropFirst().prefix(2).enumerated()).reversed(), id: \.offset) { idx, asset in
                card(asset)
                    .id(asset.localIdentifier)
                    .scaleEffect(idx == 0 ? 0.97 : 0.94)
                    .offset(x: CGFloat(idx + 1) * 6, y: CGFloat(idx + 1) * 6)
                    .opacity(idx == 0 ? 0.7 : 0.4)
            }
            // Hero with caption — the chronological FIRST photo of THIS burst.
            // Keyed by the asset id so it reloads live as the thumb moves between
            // bursts (AsyncPHImage loads in onAppear, which only re-fires on a new id).
            ZStack(alignment: .bottomLeading) {
                card(burst.firstAsset)
                    .id(burst.firstAsset?.localIdentifier ?? burst.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(burst.label)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text(captionLine)
                        .font(.system(size: 12, weight: showMoment ? .semibold : .regular))
                        .foregroundStyle(showMoment ? Color.accentColor : .white.opacity(0.85))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                           startPoint: .bottom, endPoint: .top))
            }
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private var captionLine: String {
        let n = burst.photoCount
        let photos = "\(n) photo\(n == 1 ? "" : "s")"
        return burst.subtitle.isEmpty ? photos : "\(burst.subtitle) · \(photos)"
    }

    @ViewBuilder private func card(_ asset: PHAsset?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground))
            if let asset {
                // Scrubber preview card displays at cardW×cardH; request that size (scaled to
                // native pixels inside AsyncPHImage) so it loads fast and stays sharp.
                AsyncPHImage(asset: asset, service: service, targetSize: CGSize(width: cardW, height: cardH))
            }
        }
        .frame(width: cardW, height: cardH)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Shared top controls (deck + gallery)

struct MemoryControlsBar: View {
    @Binding var mode: MemoryViewMode
    let service: PhotoLibraryService
    let hiddenCount: Int
    let onReviewHidden: () -> Void
    var dark: Bool

    @State private var showReminder = false
    @State private var showFavorites = false

    private var tint: Color { dark ? .white : .primary }

    var body: some View {
        HStack(spacing: 10) {
            // Masthead: a quiet, letter-spaced "ENCORE" wordmark sits above the section title, the way
            // a magazine sets its name over a department head. Low-contrast serif small caps so it
            // reads as the app's signature without competing with the photos or the controls. It lives
            // in the persistent bar, so it appears identically on every page and never moves.
            // To remove or tune: delete the ENCORE Text line, or adjust size/tracking/opacity below.
            VStack(alignment: .leading, spacing: 1) {
                Text("ENCORE")
                    .font(.system(size: 10, weight: .semibold, design: .serif))
                    .tracking(2.5)
                    .foregroundStyle(tint.opacity(0.5))
                Text("On this day").font(.headline).foregroundStyle(tint)
            }
            Spacer()
            iconButton(mode == .deck ? "square.grid.2x2" : "rectangle.stack") {
                withAnimation(.snappy) { mode = (mode == .deck ? .gallery : .deck) }
            }
            Menu {
                Button {
                    showFavorites = true
                } label: {
                    Label("View favorites", systemImage: "heart")
                }
                Button {
                    showReminder = true
                } label: {
                    Label("Daily reminder…", systemImage: "bell")
                }
                if CalendarService.calendarEnabled && !service.calendarAuthorized {
                    Button { service.connectCalendar() } label: {
                        Label("Connect calendar", systemImage: "calendar")
                    }
                }
                if hiddenCount > 0 {
                    Button { onReviewHidden() } label: {
                        Label("Review \(hiddenCount) hidden", systemImage: "eye.slash")
                    }
                }
            } label: {
                iconLabel("ellipsis")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .sheet(isPresented: $showReminder) {
            ReminderSettingsView(service: service)
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(service: service)
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(name) }
    }

    private func iconLabel(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(.ultraThinMaterial, in: Circle())
    }
}

/// Simple progress bar with the photo count on the same line.
private struct ProgressTrack: View {
    let progress: Double
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(0, geo.size.width * progress), height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 8)

            if total > 0 {
                Text("\(position) / \(total)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}
