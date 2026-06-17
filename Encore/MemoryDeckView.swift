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
    /// When true the outer paging ScrollView stops scrolling. We hold this true on the
    /// home page so the home peek card's own drag — not the ScrollView's paging gesture —
    /// owns the swipe-up. Without this the paging recognizer hijacks the gesture and the
    /// deck flips to the first photo before the card can track the finger.
    @State private var homeScrollLocked = true
    /// Flipped every time the deck returns to the home page (even without a view teardown) so
    /// the realized home page can reset its reveal state back to the peek view.
    @State private var homeReturnSignal = false
    /// Drives the top chrome (controls + progress) AND the scrubber, DECOUPLED from `onBookend`.
    /// On the swipe-up reveal the deck swaps from "home" to the first photo at the exact instant
    /// the finger-tracked expansion finishes, which is also when `onBookend` flips false. If the
    /// chrome keyed straight off `onBookend` it would fade in and the scrubber would insert ON
    /// THAT SAME FRAME, so the screen "bumped into place" mid-motion. Instead we hold this false
    /// through the handoff and flip it true a calm beat later, so the chrome eases in over a
    /// settled full-screen photo. It drops false immediately on any return to a bookend.
    @State private var chromeVisible = false
    /// Cancels a pending deferred chrome reveal if we leave the page before it fires.
    @State private var chromeRevealWork: DispatchWorkItem?
    /// Delay before the top chrome + scrubber ease in after a reveal. Kept a beat AFTER the home
    /// page's fixed glide (DeckHomePage.revealGlideDuration ≈ 0.78s) so the chrome never appears
    /// mid-glide. If the glide duration changes, bump this to stay >= glide + ~0.2s.
    private let chromeRevealDelay: Double = 1.0

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
    private var onBookend: Bool { currentID == "home" || currentID == "end" || currentID == nil }

    /// Scrub stops: every Moment plus the home/end bookends as reachable end caps.
    /// The thumb can land on any burst; speed only changes what the overlay reveals.
    private var momentStops: [Int] {
        bursts.indices.filter { i in bursts[i].year != nil || i == 0 || i == bursts.count - 1 }
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
            .scrollDisabled(homeScrollLocked)
            .ignoresSafeArea()

            VStack(spacing: 16) {
                MemoryControlsBar(mode: $mode, service: service,
                                  hiddenCount: hiddenCount, onReviewHidden: onReviewHidden,
                                  dark: true)
                ProgressTrack(progress: progress, position: photoPosition, total: totalPhotos)
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.28), value: chromeVisible)

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
            // Re-lock the moment we land back on home so the next swipe-up is owned by the
            // peek card again, not the paging recognizer. Toggle the return signal so the
            // (possibly still-realized) home page resets its reveal state to the peek view.
            if new == "home" {
                homeScrollLocked = true
                homeReturnSignal.toggle()
            }
            updateChrome(for: new)
        }
        .sheet(isPresented: $sharePicker) {
            MomentSharePicker(moments: allMoments, service: service)
        }
    }

    /// Show/hide the top chrome + scrubber, decoupled from the reveal motion. Landing on a
    /// bookend (home/end) hides it at once. Landing on a real photo DEFERS the reveal a beat so
    /// it eases in over a settled photo instead of bumping in on the same frame as the handoff.
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
        // The reveal writes currentID at the START of the expansion (build 32 reorder) and the
        // open is now a fixed gentle glide of ~0.78s (DeckHomePage.revealGlideDuration, build 36),
        // so wait out the full glide PLUS a beat before easing the chrome in. Otherwise the menu /
        // progress bar / scrubber start appearing while the photo is still gliding up, which reads
        // as the swipe-up jerk. This MUST stay >= the glide duration + a beat (0.78 + ~0.22 = 1.0).
        // This delay only gates the first false->true (the reveal); normal deck navigation keeps
        // the chrome already visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + chromeRevealDelay, execute: work)
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
                         firstTargetID: firstPhoto.map { "p-" + $0.id } ?? "end",
                         service: service,
                         mode: $mode,
                         hiddenCount: hiddenCount,
                         onReviewHidden: onReviewHidden,
                         onInteract: { clearBadgeOnce() },
                         // PRE-POSITION (fires at the START of the reveal spring, while the
                         // ScrollView is still scroll-locked and the reveal card is covering the
                         // screen). Programmatically settle the paging ScrollView onto the first
                         // photo's page boundary NOW, inside a disablesAnimations transaction. The
                         // reveal card hides this reposition, so it is invisible — and because the
                         // ScrollView is already parked there, the later unlock causes no paging
                         // settle. This is what kills the "bumps into place" second motion.
                         onRevealPrepare: { targetID in
                             if let idx = indexByID[targetID], idx < items.count,
                                case .photo(let p, _) = items[idx] {
                                 service.prioritize([p.asset])
                             }
                             var tx = Transaction(); tx.disablesAnimations = true
                             withTransaction(tx) { currentID = targetID }
                         },
                         // UNLOCK (fires AFTER the reveal spring has finished). The ScrollView is
                         // already parked on the first photo from onRevealPrepare, so flipping
                         // scrollDisabled false here produces NO settle/jump. Done inside a
                         // disablesAnimations transaction for the same reason.
                         onReveal: {
                             var tx = Transaction(); tx.disablesAnimations = true
                             withTransaction(tx) { homeScrollLocked = false }
                         },
                         returnedToHome: homeReturnSignal)
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
    let firstTargetID: String
    let service: PhotoLibraryService
    let mode: Binding<MemoryViewMode>
    let hiddenCount: Int
    let onReviewHidden: () -> Void
    let onInteract: () -> Void
    /// Fired at the START of the reveal spring, while the ScrollView is still scroll-locked and
    /// the reveal card covers the screen. The parent pre-positions the paging ScrollView onto the
    /// first photo's page boundary (un-animated), hidden behind the full-screen card.
    let onRevealPrepare: (String) -> Void
    /// Fired AFTER the reveal spring finishes. The parent re-enables scrolling (un-animated); the
    /// ScrollView is already parked on the first photo, so there is no second settle motion.
    let onReveal: () -> Void
    /// The parent toggles this on every return-to-home. The home page can stay realized in the
    /// LazyVStack across a reveal, so onAppear is not guaranteed to re-fire; observing this
    /// guarantees the reveal state resets and the card returns to its peek state every time.
    let returnedToHome: Bool

    /// Automatic idle drift. Toggles between two `idleOffset` endpoints under a repeatForever
    /// ease so the peeking photo gently rises and settles ON ITS OWN as a "swipe me up" hint.
    /// This drives its own dedicated `.offset(y:)` transform layer, fully decoupled from the
    /// drag/reveal offset so the two transforms never share a value or fight an animation.
    /// Suppressed while the finger is down or a reveal is committing.
    @State private var idleLifted = false
    /// One-shot entrance: header + mosaic ease in on appear.
    @State private var entered = false
    /// Staged entrance, the final beat: after the header + mosaic are in, the peek card
    /// springs up from below the bottom edge into its resting peek slice, THEN the idle bob
    /// arms. False = card parked below the screen; true = card at its resting peek position.
    @State private var peekEntered = false
    @State private var shareSelection: ShareSelection?

    /// Finger-tracked vertical translation of the peeking photo (points). Negative = up.
    /// The photo and its overlaid affordance share this one offset, so they move 1:1.
    @GestureState private var dragOffset: CGFloat = 0

    /// Reveal progress, 0 = peek at rest, 1 = photo fully expanded to full screen. On
    /// release past threshold it animates to 1 (continuous expansion); a tap also drives
    /// it to 1.
    @State private var revealProgress: CGFloat = 0
    /// True from the moment a commit starts until the parent has swapped pages, so the idle
    /// bob and the drag handler stand down and let the expansion run uninterrupted.
    @State private var revealing = false
    /// True while the home page is the settled, at-rest visible page (its top edge sits at the
    /// screen top). Driven by the geometry probe so the reset fires on EVERY return path —
    /// including the interactive swipe-down, which the parent's `currentID` signal can miss.
    @State private var atRest = false
    /// True once the home page has completed its staged entrance at least once. The geometry
    /// probe's reset is suppressed until then so the FIRST settle (home is already at rest on
    /// launch) does not short-circuit the staged pop-up by forcing the card straight to peek.
    @State private var hasEnteredOnce = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    /// True only when the page is fully at rest: no finger down, no reveal committing, nothing
    /// expanded. This is the single condition that arms/disarms the idle drift (see the
    /// `onChange(of: isIdle)` owner in `body`). Mirrors the local `idleActive` used for clarity
    /// inside the layout, but lives here so the modifier can observe it.
    private var isIdle: Bool {
        isIdleEligible && peekEntered
    }

    /// Same as `isIdle` but without the `peekEntered` requirement: true when nothing is being
    /// dragged, revealed, or committed. The staged entrance uses this to confirm it is still
    /// safe to pop the peek up (the user hasn't started interacting during the entrance beat).
    private var isIdleEligible: Bool {
        dragOffset == 0 && !revealing && revealProgress == 0
    }

    // MARK: Tunable feel constants
    /// Height of the photo slice that peeks above the bottom edge at rest. The photo is
    /// top-aligned, so its TOP is always visible.
    private let peekHeight: CGFloat = 184
    /// Idle drift travel (points) — the peeking photo automatically rises by this much and
    /// settles back, continuously. Negative = up. Tuned for a calm, clearly-visible motion.
    private let idleTravel: CGFloat = 15
    /// Calm period for one half of the idle rise/settle cycle.
    private let idleDuration: Double = 1.5
    /// How far up the finger must carry the photo (points) for the expansion to reach full
    /// screen. Drag distance maps linearly onto reveal progress over this span.
    private let pullDistance: CGFloat = 260
    /// Fraction of pullDistance past which release completes the reveal to the full photo.
    private let pullThreshold: CGFloat = 0.4
    /// THE single tunable for the open feel (build 36). Once the user clearly intends to open,
    /// the photo glides 0→1 to full screen over this fixed duration with a gentle easeInOut,
    /// DECOUPLED from how fast the finger flicked. A hard flick can no longer shoot it up: the
    /// trigger fires, finger-tracking stops, and this fixed glide always runs. Calm ~0.78s.
    private let revealGlideDuration: Double = 0.78
    /// While the finger is still down (pre-trigger) the photo moves only this fraction of the
    /// finger travel, so even the tracked portion feels gentle and damped rather than 1:1.
    private let revealTrackRatio: CGFloat = 0.45
    /// Upward finger travel (points) past which we TRIGGER the glide — a modest, deliberate pull
    /// rather than the full pullDistance. Once crossed, `completeReveal` runs the fixed glide and
    /// 1:1 tracking is abandoned for the rest of the open.
    private let revealTriggerDistance: CGFloat = 56
    /// Upward flick velocity (points/sec) that also triggers the glide even on a short, fast
    /// flick — so a quick intentional flick opens, but still via the SAME calm glide, never fast.
    private let revealTriggerVelocity: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            // Live reveal fraction: the committed glide progress, or the DAMPED finger pull —
            // whichever is larger. Pre-trigger the finger only moves the photo `revealTrackRatio`
            // of its travel (a gentle, partial follow), so even before the glide fires the motion
            // is calm. The moment the trigger fires, `revealProgress` is driven by the fixed
            // easeInOut glide and that wins, so a hard flick can never shoot the photo up — the
            // open is always the same deliberate ~0.78s glide regardless of flick speed.
            let liveReveal = max(revealProgress,
                                 min(max(-dragOffset / pullDistance, 0), 1) * revealTrackRatio)
            // The photo is laid out ONCE at full screen height (never relaid out). At rest it is
            // pushed DOWN by `restPush` so only its top `peekHeight` slice shows above the bottom
            // edge; as the reveal grows it rides UP to 0 and fills the screen. Driving the reveal
            // with this single GPU `.offset` (instead of animating the frame height every frame)
            // is what makes the motion smooth.
            let restPush = geo.size.height - peekHeight
            // Small downward give so the peek can't be pushed noticeably below its rest slice.
            let downGive = max(min(dragOffset, 7), 0) * (1 - liveReveal)
            // One vertical offset for the whole reveal: restPush (peek) → 0 (full screen) as
            // liveReveal → 1. During the drag liveReveal is the finger fraction (tracks the thumb
            // 1:1, un-animated because dragOffset is @GestureState); on release revealProgress
            // takes over and the spring keyed on it carries the motion to completion.
            let revealTranslate = restPush * (1 - liveReveal) + downGive
            // The drift is keyed SOLELY on `idleLifted`, the single source the repeatForever
            // animation observes. It re-arms via the isIdle owner (see onChange below) so the
            // autoreversing loop restarts cleanly every time the page returns to idle.
            let idleOffset: CGFloat = idleLifted ? -idleTravel : 0
            // Staged entrance: until the peek has entered, park the card fully below its rest
            // slice so it sits off-screen, then spring to 0 (its resting peek). This is its own
            // transform layer so it never shares a value with the idle or reveal transforms.
            let entranceOffset: CGFloat = peekEntered ? 0 : (peekHeight + 24)
            // The affordance overlay fades as the photo takes over the screen.
            let affordanceOpacity = Double(1 - min(liveReveal * 1.6, 1))

            ZStack(alignment: .bottom) {
                Color.black

                VStack(spacing: 20) {
                    header
                        .frame(maxWidth: .infinity)
                        .padding(.top, 116)

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

                    Spacer(minLength: 0)
                }
                .padding(.bottom, peekHeight + 10)
                .opacity(entered ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: entered)

                // The peeking photo — the visual swipe-up affordance. It no longer owns the
                // gesture; the reveal is driven by the full-page `revealGesture` so a swipe
                // anywhere works, while a tap still falls through to the mosaic tile buttons.
                // Laid out at FULL height; the reveal is a pure GPU `.offset` slide (see
                // revealTranslate) rather than a per-frame frame-height change, so it is smooth.
                peekPhoto(width: geo.size.width, height: geo.size.height,
                          affordanceOpacity: affordanceOpacity)
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
                    // Single reveal transform. Finger changes (dragOffset / @GestureState) pass
                    // through DAMPED (revealTrackRatio) and un-animated for a gentle partial
                    // follow; only the committed glide is animated — keyed on revealProgress — so
                    // there is no competing height relayout. This implicit animation governs the
                    // revealProgress 0→1 change driven by completeReveal: a fixed, gentle easeInOut
                    // of `revealGlideDuration` so the photo always glides up calmly and elegantly,
                    // DECOUPLED from flick speed. A hard flick can no longer shoot it up (build 36).
                    .offset(y: revealTranslate)
                    .animation(.easeInOut(duration: revealGlideDuration), value: revealProgress)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(
                // Scroll-position probe. The page is sized to the scroll container, so its global
                // top edge sits at ~0 ONLY when home is the settled, at-rest visible page. This
                // fires on every return path the `currentID` signal can miss — most importantly
                // the interactive swipe-down back to home — so the reset never needs a nudge.
                GeometryReader { pageGeo in
                    Color.clear.preference(key: HomeRestKey.self,
                                           value: pageGeo.frame(in: .global).minY)
                }
            )
            .onPreferenceChange(HomeRestKey.self) { minY in
                // Threshold is generous (8pt, not 1pt): a .paging settle can park a pixel or
                // two off zero, and a too-tight check would intermittently miss the reset and
                // reintroduce the "needs a nudge" bug. The next page is a full screen away, so
                // any value well under half a screen is safe from false positives.
                let nowAtRest = abs(minY) < 8
                guard nowAtRest != atRest else { return }
                atRest = nowAtRest
                // NEVER reset mid-reveal. Pre-positioning the ScrollView onto the first photo
                // (onRevealPrepare, fired from completeReveal) moves home off the settled page
                // WHILE the reveal spring is still running. Without this guard an intermediate
                // settle could fire resetToPeek() and collapse the reveal. Only allow the
                // return-to-home reset when no reveal is in progress.
                // Skip the reset on the very first settle so the staged entrance (onAppear) owns
                // the first pop-up; only on genuine RETURNS to home does the probe snap the card
                // straight back to its resting peek.
                if nowAtRest && hasEnteredOnce && !revealing { resetToPeek() }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(revealGesture)
            .overlay(alignment: .top) {
                MemoryControlsBar(mode: mode, service: service,
                                  hiddenCount: hiddenCount, onReviewHidden: onReviewHidden,
                                  dark: true)
                    .padding(.top, 54)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(appVersionString())
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.trailing, 14).padding(.bottom, 8)
            }
        }
        .onChange(of: isIdle) { _, idle in
            // SINGLE owner of arming `idleLifted`. Whenever the page returns to the idle state
            // (finger lifts, a sub-threshold pull springs back, a reveal is abandoned), disarm
            // then re-arm on the next runloop so the repeatForever ease restarts cleanly from
            // rest rather than snapping to an endpoint and freezing. While suppressed, settle to
            // rest (0). Because arming lives only here, an in-flight reveal (isIdle == false)
            // can never have the drift set true underneath it.
            if idle {
                idleLifted = false
                DispatchQueue.main.async { if isIdle { idleLifted = true } }
            } else {
                idleLifted = false
            }
        }
        .onChange(of: returnedToHome) { _, _ in
            // The home page lives in a LazyVStack and may stay realized across a reveal, so
            // scrolling back to home does not reliably re-fire onAppear. The parent flips this
            // signal on every return-to-home; funnel through the single reset so the card always
            // returns to its peek state. (The geometry probe above covers the interactive
            // swipe-down that this signal can miss; this is the belt-and-suspenders path.)
            resetToPeek()
        }
        .onAppear {
            // Staged entrance, once per realized appear: header + mosaic ease in first
            // (`entered`), then as the final beat the peek card springs up from below the
            // bottom edge into its resting peek slice (`peekEntered`), which in turn arms the
            // idle bob via the isIdle gate. The hero is preloaded, so when the card pops up it
            // already shows the photo — no white.
            entered = true
            revealing = false
            revealProgress = 0
            if !peekEntered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard isIdleEligible else { return }
                    peekEntered = true
                    hasEnteredOnce = true
                }
            } else {
                hasEnteredOnce = true
            }
        }
        .sheet(item: $shareSelection) { sel in
            PhotoShareView(asset: sel.asset, caption: sel.caption, service: service)
        }
    }

    /// THE single reset. Whenever home becomes the settled page (fresh launch, swipe-up then
    /// swipe-back-down, any scroll, relaunch) this returns the card to its peek state: reveal
    /// cleared so `liveReveal` falls to 0 and the photo sits at peek, and the idle drift
    /// re-armed (disarm now, arm next runloop) so the autoreversing loop restarts cleanly and
    /// the affordance + photo move together. No nudge is ever required.
    private func resetToPeek() {
        idleLifted = false
        revealing = false
        revealProgress = 0
        // On returns to home (swipe-down, scrub-to-top) we do NOT replay the pop-up entrance —
        // the card belongs at its resting peek with the photo present and bobbing immediately.
        // Only the genuine first appear (peekEntered still false there) stages the pop-up.
        peekEntered = true
        DispatchQueue.main.async { if isIdle { idleLifted = true } }
    }

    /// Drive the photo the rest of the way to full screen as one continuous expansion, then
    /// hand off to the parent. The photo is already covering the screen when the handoff
    /// fires, so swapping the deck onto the first photo underneath is invisible.
    ///
    /// `fromProgress` is the DAMPED live reveal fraction at the instant the glide is triggered
    /// (release past threshold, or the in-drag trigger). We SEED `revealProgress` to it (without
    /// animation) before gliding to 1, so `liveReveal` is continuous across the handoff. Without
    /// the seed, `dragOffset` snaps to 0 the moment the gesture ends while `revealProgress` is
    /// still 0, so `liveReveal` momentarily collapses to the peek and the glide restarts from
    /// there — that was the hiccup near the top.
    private func completeReveal(fromProgress: CGFloat) {
        guard !revealing else { return }
        revealing = true
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { revealProgress = min(max(fromProgress, 0), 1) }
        // PRE-POSITION the paging ScrollView onto the first photo NOW, while it is still
        // scroll-locked and the reveal card covers the screen. The parent writes currentID
        // un-animated, so the ScrollView settles to that page boundary invisibly. `revealing`
        // is true here, so the geometry probe's reset is suppressed even though home is no
        // longer the settled page (see onPreferenceChange guard).
        onRevealPrepare(firstTargetID)
        // The fixed glide (build 36). A single gentle easeInOut of `revealGlideDuration`, fully
        // DECOUPLED from flick velocity: once we are here, the finger no longer drives the motion
        // (revealProgress wins in liveReveal), so the photo always glides up calmly over ~0.78s,
        // never fast, even on a hard flick. `revealGlideDuration` is the single source of truth so
        // the handoff delay below — and the chrome reveal delay in the parent — can't desync.
        let revealDuration = revealGlideDuration
        withAnimation(.easeInOut(duration: revealDuration)) { revealProgress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDuration) {
            // Only hand off if the reveal is still in flight. If anything cleared `revealing`
            // in this window (e.g. a reset), do not force the unlock.
            guard revealing else { return }
            // The spring has landed (card fills the screen) and the ScrollView is already parked
            // on the first photo, so unlocking now produces no second settle. The MemoryPageView
            // beneath occupies the exact same rect the reveal card showed: zero second motion.
            onReveal()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("On this day")
                .font(.footnote.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Color.accentColor)
                .textCase(.uppercase)

            Text(dateLine)
                .font(.system(size: 40, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Capsule()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 34, height: 3)
                .padding(.top, 2)

            Text("\(yearCount) \(yearCount == 1 ? "year" : "years") of memories, waiting")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Peek — the first photo peeking up with its affordance overlaid

    /// The first photo, pinned to the bottom and top-aligned so its TOP edge always shows.
    /// The grabber pill + "Swipe up to begin" label sit OVER the photo (on a subtle bottom
    /// scrim for legibility) — there is no black band above the picture. This view is purely
    /// the visual swipe-up affordance now; the reveal gesture lives on the full-page layer
    /// (`revealGesture`) so a swipe anywhere on home triggers it.
    private func peekPhoto(width: CGFloat, height: CGFloat, affordanceOpacity: Double) -> some View {
        ZStack(alignment: .top) {
            Group {
                if let firstAsset {
                    // The peek photo expands to FULL SCREEN on reveal. Load it at SCREEN resolution
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
            .opacity(affordanceOpacity)
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
        // Tap-to-open (build 36): a tap on the peek opens via the SAME fixed glide as a swipe,
        // seeded from the peek (progress 0) so it runs the full calm easeInOut. The full-page
        // `revealGesture` still owns swipes from anywhere; this just makes the obvious affordance
        // tappable too. minimumDistance on the drag keeps a tap from also starting a drag.
        .onTapGesture {
            guard !revealing else { return }
            onInteract()
            completeReveal(fromProgress: 0)
        }
    }

    /// Swipe-up reveal, attached to the WHOLE home page (full screen, natural position) so a
    /// drag anywhere — over the mosaic, the middle, or the peek photo — starts the expansion.
    /// `minimumDistance` keeps taps clean: a tap (no real movement) never starts this gesture,
    /// so it passes straight through to the mosaic tile `Button`s, while a real upward drag
    /// drives the reveal. The layer sits un-offset at its natural rect, so its hit region is
    /// correct and only the tap-vs-drag distinction separates it from the tile buttons.
    private var revealGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragOffset) { value, state, _ in
                guard !revealing else { return }
                state = max(value.translation.height, -pullDistance)
            }
            .onChanged { value in
                // IN-DRAG TRIGGER (build 36): the instant the user clearly intends to open — a
                // modest upward pull OR an upward flick velocity — fire the fixed glide and STOP
                // tracking the finger. This is what decouples the open from flick speed: a fast
                // flick trips the trigger almost immediately, but the open is still the calm
                // easeInOut glide, never a finger-driven shoot-up. We seed the glide from the
                // current DAMPED live reveal so the handoff is continuous.
                guard !revealing else { return }
                let up = -value.translation.height
                let upVelocity = -value.predictedEndTranslation.height + value.translation.height
                let pulledEnough = up >= revealTriggerDistance
                let flickedEnough = up >= 18 && upVelocity >= revealTriggerVelocity
                guard pulledEnough || flickedEnough else { return }
                onInteract()
                let seed = min(max(up / pullDistance, 0), 1) * revealTrackRatio
                completeReveal(fromProgress: seed)
            }
            .onEnded { value in
                // Fallback for a slow drag that never tripped the in-drag trigger: a release past
                // the distance threshold still opens, via the SAME fixed glide.
                guard !revealing else { return }
                let up = -value.translation.height
                let progress = min(max(up / pullDistance, 0), 1)
                if progress > pullThreshold {
                    onInteract()
                    completeReveal(fromProgress: progress * revealTrackRatio)
                }
            }
    }
}

/// Carries the home page's global top-edge position out of its GeometryReader so the page can
/// detect when it has settled back at rest (top edge ~0) and reset itself.
private struct HomeRestKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
// One stop set (every burst). The track always shows year ticks + burst sublines.
// Speed only gates the OVERLAY: fast = year only, slow = year + the burst preview.

private struct BurstScrubber: View {
    let bursts: [Burst]
    let stops: [Int]         // every Moment + home/end caps — the single stop set
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
            Text("On this day").font(.headline).foregroundStyle(tint)
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
