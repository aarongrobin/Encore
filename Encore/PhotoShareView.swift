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

    private var hasLocation: Bool { caption.placeText?.isEmpty == false }

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
        service.requestImage(for: asset, targetSize: CGSize(width: 1400, height: 1900)) { image in
            sourceImage = image
            renderCard()
        }
    }

    private func renderCard() {
        guard let sourceImage else { return }
        let effective = includeLocation
            ? caption
            : MomentCaption(yearsAgoText: caption.yearsAgoText, dateText: caption.dateText, placeText: nil)
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
