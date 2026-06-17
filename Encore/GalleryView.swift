import SwiftUI
import Photos

/// A tapped photo to open in the full-screen moment viewer.
struct MomentSelection: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let caption: MomentCaption
}

/// The "view everything" option: a clean grid of all the day's photos, grouped
/// by year. Tap any photo to open the framed moment + share.
struct GalleryView: View {
    let memories: [YearMemory]
    let service: PhotoLibraryService
    @Binding var mode: MemoryViewMode
    let hiddenCount: Int
    let onReviewHidden: () -> Void

    @State private var moment: MomentSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 46) // clearance for the control bar

                    ForEach(memories) { memory in
                        if !memory.visiblePhotos.isEmpty || !memory.events.isEmpty {
                            section(for: memory)
                        }
                    }

                    if hiddenCount > 0 {
                        Button(action: onReviewHidden) {
                            Label("Review \(hiddenCount) hidden \(hiddenCount == 1 ? "photo" : "photos")",
                                  systemImage: "eye.slash")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }

            MemoryControlsBar(mode: $mode, service: service,
                              hiddenCount: hiddenCount, onReviewHidden: onReviewHidden,
                              dark: false)
        }
        .sheet(item: $moment) { selection in
            PhotoShareView(asset: selection.asset, caption: selection.caption, service: service)
        }
    }

    private func section(for memory: YearMemory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.headline)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                if let place = memory.placeName {
                    HStack(spacing: 5) {
                        Image(systemName: memory.isTravel ? "airplane" : "mappin.and.ellipse")
                        Text(memory.isTravel ? "You were in \(place)" : place)
                    }
                    .font(.footnote)
                    .foregroundStyle(memory.isTravel ? Color.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 16)

            ForEach(memory.events) { event in
                EventRow(event: event).padding(.horizontal, 16)
            }

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(memory.visiblePhotos) { photo in
                    Button {
                        moment = MomentSelection(asset: photo.asset, caption: caption(for: memory))
                    } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                AsyncPHImage(asset: photo.asset, service: service,
                                             targetSize: CGSize(width: 400, height: 400))
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func caption(for memory: YearMemory) -> MomentCaption {
        MomentCaption(yearsAgoText: memory.headline,
                      dateText: memory.fullDateString,
                      placeText: memory.placeName)
    }
}

private struct EventRow: View {
    let event: MemoryEvent
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: event.icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
