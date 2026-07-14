import SwiftUI
import Photos
import UIKit

/// Fast, reliable share for a single photo. Pre-renders the framed card from the
/// in-memory image (no white-screen delay) and shares the image FILE via ShareLink
/// so no text is added to the message. Subtle toggle to drop the location.
struct PhotoShareView: View {
    let asset: PHAsset
    let caption: MomentCaption
    let service: PhotoLibraryService

    @Environment(\.dismiss) private var dismiss
    @State private var sourceImage: UIImage?
    @State private var card: UIImage?
    @State private var shareURL: URL?
    @State private var includeLocation = true
    /// This photo's OWN resolved place (build 39, MAR-40), filled in on appear when the asset has
    /// its own GPS. Overrides the moment-level caption place so the share is correct per-photo.
    @State private var resolvedPlace: String?

    /// The place to print on the share card. Strictly the photo's OWN location: if the asset
    /// carries no GPS of its own (the typical "shared from someone else" case — re-saved photos
    /// usually have GPS stripped), show NO place rather than inheriting a sibling photo's city.
    /// When it does have a location, prefer its freshly-resolved place, falling back to the
    /// moment caption only until that resolves.
    private var effectivePlaceText: String? {
        guard asset.location != nil else { return nil }
        return resolvedPlace ?? caption.placeText
    }

    private var hasLocation: Bool { effectivePlaceText?.isEmpty == false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 0)

                if let card {
                    Image(uiImage: card)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 440)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(height: 380)
                        .overlay(ProgressView())
                }

                Spacer(minLength: 0)

                if hasLocation {
                    Toggle(isOn: $includeLocation) {
                        Label("Show location", systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                    }
                    .tint(.accentColor)
                    .padding(.horizontal, 8)
                }

                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                } else {
                    Capsule().fill(Color.accentColor.opacity(0.4))
                        .frame(height: 52)
                        .overlay(Text("Preparing…").foregroundStyle(.white))
                }
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: loadAndRender)
        .onChange(of: includeLocation) { _, _ in renderCard() }
    }

    private func loadAndRender() {
        guard sourceImage == nil else { return }
        // Resolve THIS photo's own place (nil if it has no GPS of its own). Re-render when it lands.
        if asset.location != nil {
            service.resolvePlace(for: asset) { place in
                if let place { resolvedPlace = place }
                renderCard()
            }
        }
        service.requestImage(for: asset, targetSize: CGSize(width: 1400, height: 1900)) { image in
            sourceImage = image
            renderCard()
        }
    }

    private func renderCard() {
        guard let sourceImage else { return }
        // Use the photo's OWN place (effectivePlaceText), gated by the show-location toggle.
        let place = includeLocation ? effectivePlaceText : nil
        let effective = MomentCaption(yearsAgoText: caption.yearsAgoText,
                                      dateText: caption.dateText, placeText: place)
        let rendered = renderShareCard(image: sourceImage, caption: effective)
        withAnimation(.easeOut(duration: 0.15)) { card = rendered }

        // Write to a temp file so the share carries only the image (no caption text).
        if let rendered, let data = rendered.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Encore-memory.png")
            try? data.write(to: url)
            shareURL = url
        }
    }
}
