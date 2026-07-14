import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var service = PhotoLibraryService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = !PreferenceStore.shared.onboardingComplete

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView {
                    PreferenceStore.shared.onboardingComplete = true
                    showOnboarding = false
                    service.start()
                }
            } else {
                switch service.state {
                case .loaded(let memories):
                    MemoriesView(memories: memories, service: service)
                default:
                    NavigationStack {
                        stateContent
                            .navigationTitle("Encore")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .onAppear {
            if !showOnboarding, case .idle = service.state { service.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.refreshSchedule() }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch service.state {
        case .denied:
            PermissionDeniedView()
        case .empty:
            EmptyMemoriesView(dateString: Self.todayString)
        default:
            // The startup sequence: one beautiful bundled stock photo, blurred, under a progress bar
            // that advances across the wait. No preview of the user's own photos (build 42, MAR-41).
            // The bar must visibly fill to 100% before home appears: it watches `loadingFinished`
            // (data ready), eases to full, then calls `finalizeHandoff()` to swap to home (build 43).
            LoadingView(dateString: Self.todayString,
                        isFinishing: service.loadingFinished,
                        onFinished: { service.finalizeHandoff() })
        }
    }

    static var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }
}

/// Holds the view-mode toggle (flip-through deck vs. full gallery) and the
/// hidden-photos review sheet shared by both.
private struct MemoriesView: View {
    let memories: [YearMemory]
    let service: PhotoLibraryService

    @State private var mode: MemoryViewMode = .deck
    @State private var showHidden = false
    @State private var showNotificationOptIn = false
    @State private var optInChecked = false

    private var allHidden: [MemoryPhoto] { memories.flatMap { $0.hiddenPhotos } }

    var body: some View {
        Group {
            switch mode {
            case .deck:
                MemoryDeckView(memories: memories, service: service, mode: $mode,
                               hiddenCount: allHidden.count, onReviewHidden: { showHidden = true })
            case .gallery:
                GalleryView(memories: memories, service: service, mode: $mode,
                            hiddenCount: allHidden.count, onReviewHidden: { showHidden = true })
            }
        }
        .sheet(isPresented: $showHidden) {
            HiddenPhotosView(hiddenPhotos: allHidden, service: service)
        }
        .sheet(isPresented: $showNotificationOptIn) {
            NotificationOptInView(service: service) { showNotificationOptIn = false }
        }
        .onAppear {
            // First open only (MAR-45): once the memories are up, offer the daily-reminder opt-in.
            // Guarded by a one-shot local flag + the persisted prompt flag so it never re-appears,
            // and skipped if a reminder is already on. Briefly delayed so the loading→home handoff
            // settles before the sheet slides up.
            guard !optInChecked else { return }
            optInChecked = true
            if !PreferenceStore.shared.notificationPromptShown,
               !PreferenceStore.shared.dailyReminderEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    showNotificationOptIn = true
                }
            }
        }
    }
}

// MARK: - Non-loaded states

/// The startup / "Finding your memories" sequence (build 42, MAR-41). Aaron's decisive simplification
/// over the build-41 AI-teaser preview ("too many things happening — black screen, quick photo, loads
/// too fast"): just ONE beautiful bundled stock photo (cities, fjords, mountains, an underwater
/// jellyfish — the kind of tasteful imagery Apple ships on its own screens), heavily blurred but still
/// recognizable, as the backdrop from frame one. No gradient-first state, no preview of the user's own
/// photos, no year overlay. Underneath, a progress bar advances across the wait. A deliberate minimum
/// hold (PhotoLibraryService.minimumLoadingDisplay) keeps it up as a calm beat while the full photo
/// set finishes loading in the background, then it hands off to the home cover without the picture
/// changing.
private struct LoadingView: View {
    let dateString: String
    /// Flips true the instant the data is ready (and the minimum beat has passed). The bar then eases
    /// the rest of the way to a full 100% and, once it reads full, calls `onFinished`.
    let isFinishing: Bool
    /// Released by the bar after it has visibly settled at 100% — performs the actual swap to home.
    let onFinished: () -> Void

    /// One bundled stock photo (LoadingStock1…10), picked ONCE per launch and never changed mid-load.
    /// A @State default initializer runs a single time per view identity, so re-renders during the load
    /// never reshuffle it — Aaron: "load up without changing the pictures." Picking it here (not in a
    /// computed property) is what makes that guarantee hold.
    @State private var stockName = "LoadingStock\(Int.random(in: 1...10))"

    var body: some View {
        ZStack {
            // The bundled stock photo, heavily blurred but still recognizable. Bundled means it draws
            // immediately — no decode wait, no gradient-first placeholder — so the blurred backdrop is
            // there from frame one.
            Image(stockName)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .blur(radius: 12)
                .overlay(
                    // A bottom-weighted scrim keeps the text legible over the blur.
                    LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                )

            VStack(spacing: 12) {
                Spacer()
                Text("Finding your memories")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Text(dateString)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                LoadingProgressBar(isFinishing: isFinishing, onFilled: onFinished)
                    .frame(width: 220, height: 4)
                    .padding(.top, 18)
                Spacer().frame(height: 120)
            }
        }
        .overlay(alignment: .bottom) {
            // Build number, unmissable on every launch, so it's always obvious which build is
            // actually installed (the home-screen version tag can sit behind the peek card).
            Text(appVersionString())
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 28)
        }
    }
}

/// The loading-screen progress bar (build 43, MAR-41). Build 40's bar jerked and stuck on the right
/// because an ancestor animation (the photo cross-fade) drove its width. This one is immune: its fill
/// is a pure function of wall-clock time, sampled every frame by `TimelineView(.animation)`. There is
/// no animatable `@State` the parent can re-drive and no implicit `.animation` modifier, so no
/// ancestor animation can touch it — it advances on its own clock.
///
/// Two phases, both time-based so neither can snap:
///   1. Natural creep — one smooth exponential ease toward (but never reaching) `ceiling`, so a long
///      load keeps inching forward instead of freezing.
///   2. Finish — when `isFinishing` flips true (data ready + minimum beat passed), the bar eases from
///      wherever it is to a full 1.0 over `finishDuration`, holds for `settle`, then calls `onFilled`.
/// The hand-off to home is gated on that `onFilled`, so the bar is ALWAYS visibly full before dismiss.
/// `isFinishing` is guaranteed to fire by `PhotoLibraryService.loadGateTimeout` (~9s), so a stuck load
/// still completes and dismisses — there is no hang path.
private struct LoadingProgressBar: View {
    let isFinishing: Bool
    let onFilled: () -> Void

    @State private var start = Date()
    @State private var finishStart: Date?
    @State private var fillAtFinish: CGFloat = 0
    @State private var reported = false

    /// Shape of the natural creep, kept matched to `PhotoLibraryService.minimumLoadingDisplay` so the
    /// bar is most of the way up right as the finish phase begins.
    private let window: TimeInterval = 2.6
    /// The natural creep approaches this and stops; only the finish phase reaches a full 1.0.
    private let ceiling: CGFloat = 0.9
    /// How long the final ease from the creep value to 1.0 takes.
    private let finishDuration: TimeInterval = 0.5
    /// A brief, visible hold at 100% before releasing the hand-off, so the full bar is unmistakable.
    private let settle: TimeInterval = 0.25

    /// One smooth, continuous exponential ease toward `ceiling` — no slope kink (the old piecewise
    /// curve had one at `window`). `tau` sets the pace: smaller is faster early.
    private func naturalFraction(_ t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        let tau = window / 2.4
        return CGFloat(Double(ceiling) * (1 - exp(-t / tau)))
    }

    private func fraction(at now: Date) -> CGFloat {
        if let finishStart {
            let p = min(1.0, now.timeIntervalSince(finishStart) / finishDuration)
            let eased = 1 - pow(1 - p, 3)   // cubic ease-out
            return fillAtFinish + (1 - fillAtFinish) * CGFloat(eased)
        }
        return naturalFraction(now.timeIntervalSince(start))
    }

    /// Capture where the creep is and ease to full. Guarded so it runs once; schedules the single
    /// `onFilled` after the bar has reached and held 100%.
    private func beginFinish() {
        guard finishStart == nil else { return }
        fillAtFinish = naturalFraction(Date().timeIntervalSince(start))
        finishStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + finishDuration + settle) {
            guard !reported else { return }
            reported = true
            onFilled()
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white.opacity(0.95))
                        .frame(width: geo.size.width * fraction(at: context.date))
                }
            }
        }
        .onChange(of: isFinishing) { _, finishing in
            if finishing { beginFinish() }
        }
        .onAppear {
            if isFinishing { beginFinish() }
        }
    }
}

private struct EmptyMemoriesView: View {
    let dateString: String
    var body: some View {
        ContentUnavailableView {
            Label("No memories yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("You don't have any photos from \(dateString) in past years. Check back tomorrow.")
        }
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photo access needed", systemImage: "lock.fill")
        } description: {
            Text("Encore needs access to your photo library to find memories from this date. Your photos never leave your device.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
