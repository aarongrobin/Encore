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
            LoadingView(teaser: service.teaserImage)
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
    }
}

// MARK: - Non-loaded states

/// The "Finding your memories" state. Once the on-device scorer has picked a teaser (a high-scoring
/// past memory), it fades in softly behind the text as a tease of what's coming. Until then it's the
/// plain centered spinner, so the teaser never delays the load — it just upgrades the screen when
/// ready and hands off into the home cover when loading completes.
private struct LoadingView: View {
    let teaser: UIImage?

    var body: some View {
        ZStack {
            if let teaser {
                Image(uiImage: teaser)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(
                        // Darken + blur so the photo reads as an ambient backdrop, not a finished
                        // photo — the foreground text stays legible and the reveal feels gentle.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(Color.black.opacity(0.35))
                            .ignoresSafeArea()
                    )
                    .transition(.opacity)
            }

            VStack(spacing: 16) {
                ProgressView()
                    .tint(teaser == nil ? nil : .white)
                Text("Finding your memories…")
                    .foregroundStyle(teaser == nil ? Color.secondary : .white)
                    .shadow(color: .black.opacity(teaser == nil ? 0 : 0.4), radius: 6, y: 1)
            }
        }
        .overlay(alignment: .bottom) {
            // Build number, unmissable on every launch, so it's always obvious which build is
            // actually installed (the home-screen version tag can sit behind the peek card).
            Text(appVersionString())
                .font(.caption2)
                .foregroundStyle((teaser == nil ? Color.secondary : Color.white).opacity(0.7))
                .padding(.bottom, 28)
        }
        .animation(.easeOut(duration: 0.5), value: teaser != nil)
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
