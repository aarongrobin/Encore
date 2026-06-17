import SwiftUI
import Photos

/// The photos the user hearted while flipping through their memories. Stored
/// locally as asset identifiers (never the system Photos "Favorites"). Tap any
/// photo to open the framed moment + share, mirroring the gallery.
struct FavoritesView: View {
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var moment: MomentSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView("No favorites yet",
                                           systemImage: "heart",
                                           description: Text("Tap the heart on a photo while you look back, and it'll show up here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                Button {
                                    moment = MomentSelection(asset: asset, caption: caption(for: asset))
                                } label: {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            AsyncPHImage(asset: asset, service: service,
                                                         targetSize: CGSize(width: 400, height: 400))
                                        }
                                        .clipped()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $moment) { selection in
                PhotoShareView(asset: selection.asset, caption: selection.caption, service: service)
            }
        }
        .onAppear { assets = service.likedAssets() }
    }

    private func caption(for asset: PHAsset) -> MomentCaption {
        let year = asset.creationDate.map { Calendar.current.component(.year, from: $0) }
        if let year { return momentCaption(forYear: year) }
        return MomentCaption(yearsAgoText: "A favorite", dateText: "", placeText: nil)
    }
}
