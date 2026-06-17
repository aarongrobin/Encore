import SwiftUI
import Photos

/// Lets the user review photos the on-device model hid (screenshots, documents,
/// clutter) and overrule it. Every show/hide choice is recorded with a reason so
/// the app learns what this person actually wants to keep.
struct HiddenPhotosView: View {
    let hiddenPhotos: [MemoryPhoto]
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MemoryPhoto?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        NavigationStack {
            Group {
                if hiddenPhotos.isEmpty {
                    ContentUnavailableView("Nothing hidden",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every photo from this day is showing in your memories."))
                } else {
                    ScrollView {
                        Text("These were set aside as probably-not-memories. Tap any photo to bring it back.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(hiddenPhotos) { photo in
                                Button { selected = photo } label: {
                                    AsyncPHImage(asset: photo.asset, service: service,
                                                 targetSize: CGSize(width: 240, height: 240))
                                        .frame(height: 104)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(alignment: .bottomLeading) {
                                            if photo.score.isScreenshot {
                                                Label("Screenshot", systemImage: "camera.viewfinder")
                                                    .labelStyle(.iconOnly)
                                                    .font(.caption2)
                                                    .padding(4)
                                                    .background(.ultraThinMaterial, in: Circle())
                                                    .padding(4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Hidden photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selected) { photo in
                HiddenPhotoDecisionSheet(photo: photo, service: service)
                    .presentationDetents([.medium])
            }
        }
    }
}

/// The show/hide decision + reason capture for one hidden photo.
private struct HiddenPhotoDecisionSheet: View {
    let photo: MemoryPhoto
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var showReasons = false

    private let reasons = ["It's a good memory", "People I love", "A place I went",
                           "Something I made", "Just because"]

    var body: some View {
        VStack(spacing: 18) {
            AsyncPHImage(asset: photo.asset, service: service,
                         targetSize: CGSize(width: 800, height: 800), contentMode: .fit)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 8)

            if let reason = photo.score.reason {
                Text("Hidden because: \(reason.lowercased())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if showReasons {
                VStack(spacing: 10) {
                    Text("Nice — why is this one worth keeping?")
                        .font(.headline)
                    FlowChips(options: reasons) { reason in
                        PreferenceStore.shared.markShown(photo.id, reason: reason)
                        service.refreshVisibility()
                        dismiss()
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        // Agree with the model — record the signal.
                        PreferenceStore.shared.markHidden(photo.id, reason: photo.score.reason ?? "Not a memory")
                        service.refreshVisibility()
                        dismiss()
                    } label: {
                        Text("Keep hidden")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showReasons = true
                    } label: {
                        Text("Show in memories")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

/// Simple wrapping chip row.
private struct FlowChips: View {
    let options: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlexibleWrap(options, spacing: 8) { option in
            Button(option) { onTap(option) }
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(.primary)
        }
    }
}

/// A minimal flow layout that wraps its children onto multiple lines.
private struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

/// iOS 16+ Layout that lays out subviews left-to-right, wrapping as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
