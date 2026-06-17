import SwiftUI
import Photos

/// End-of-day "Share a memory": an on-device curated pick of one photo per moment.
/// Tap one to share it (with the location toggle).
struct MomentSharePicker: View {
    let moments: [Moment]
    let service: PhotoLibraryService

    @Environment(\.dismiss) private var dismiss
    @State private var selection: ShareSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 3) {
                    Text(spanText).font(.subheadline.weight(.medium))
                    Text("Choose a favorite to share")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal).padding(.top, 4)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(curated, id: \.moment.id) { entry in
                        Button {
                            selection = ShareSelection(asset: entry.asset, caption: caption(for: entry.moment))
                        } label: {
                            tile(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Share a memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selection) { sel in
                PhotoShareView(asset: sel.asset, caption: sel.caption, service: service)
            }
        }
    }

    private var curated: [(moment: Moment, asset: PHAsset)] {
        moments.compactMap { m in m.best.map { (moment: m, asset: $0.asset) } }
    }

    private var spanText: String {
        let current = Calendar.current.component(.year, from: Date())
        let oldest = moments.map { $0.year }.min() ?? current
        let span = max(1, current - oldest)
        return span <= 1 ? "Memories from this day" : "Memories over the past \(span) years"
    }

    private func tile(_ entry: (moment: Moment, asset: PHAsset)) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncPHImage(asset: entry.asset, service: service,
                             targetSize: CGSize(width: 500, height: 500))
            }
            .overlay(alignment: .bottomLeading) {
                Text(String(entry.moment.year))
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                               startPoint: .bottom, endPoint: .top))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func caption(for moment: Moment) -> MomentCaption {
        let yearsAgo = Calendar.current.component(.year, from: Date()) - moment.year
        let yearsText = yearsAgo == 1 ? "1 year ago today" : "\(yearsAgo) years ago today"

        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = moment.year
        comps.month = cal.component(.month, from: Date())
        comps.day = cal.component(.day, from: Date())
        let date = cal.date(from: comps) ?? Date()
        let formatter = DateFormatter(); formatter.dateFormat = "MMMM d, yyyy"

        return MomentCaption(yearsAgoText: yearsText,
                             dateText: formatter.string(from: date),
                             placeText: moment.placeName)
    }
}

struct ShareSelection: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let caption: MomentCaption
}
