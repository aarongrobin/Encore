import SwiftUI
import Photos
import UIKit

/// The text shown beneath a photo on a shareable card.
struct MomentCaption {
    let yearsAgoText: String   // "9 years ago today"
    let dateText: String       // "June 10, 2016"
    let placeText: String?     // "Lisbon, Portugal"
}

/// The elegant, self-contained card that gets shared. Designed to scale: all
/// metrics derive from `width`, so the same view renders crisply on screen and
/// at 1080px for export. A framed gallery print, not a social-media sticker.
struct ShareableCard: View {
    let image: UIImage
    let caption: MomentCaption
    var width: CGFloat = 375

    private var s: CGFloat { width / 375 }   // scale unit

    var body: some View {
        VStack(spacing: 0) {
            // The photo — a clean 4:5 frame, the most shareable aspect.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width - 22 * s, height: (width - 22 * s) * 1.25)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8 * s, style: .continuous))
                .padding(11 * s)

            // The caption "mat"
            VStack(spacing: 6 * s) {
                Text(caption.yearsAgoText)
                    .font(.system(size: 25 * s, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.13))

                Text(caption.dateText)
                    .font(.system(size: 14 * s, weight: .regular))
                    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.45))

                if let place = caption.placeText {
                    HStack(spacing: 4 * s) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12 * s))
                        Text(place)
                            .font(.system(size: 13 * s, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.45))
                    .padding(.top, 1 * s)
                }

                Text("Encore, relive your photo memories 📷")
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                    .padding(.top, 12 * s)
            }
            .padding(.horizontal, 18 * s)
            .padding(.bottom, 22 * s)
            .padding(.top, 4 * s)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22 * s, style: .continuous))
    }
}

/// Rasterize the elegant framed card at export width for sharing. Renders with a
/// transparent margin + soft shadow (no black corners) so it floats cleanly on
/// any chat background.
@MainActor
func renderShareCard(image: UIImage, caption: MomentCaption, width: CGFloat = 1080) -> UIImage? {
    let margin = width * 0.05
    let content = ShareableCard(image: image, caption: caption, width: width)
        .padding(margin)
        .shadow(color: .black.opacity(0.18), radius: width * 0.02, y: width * 0.012)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    renderer.isOpaque = false
    return renderer.uiImage
}

/// Full-screen viewer for a single memory with an ambient backdrop and Share.
struct PhotoMomentView: View {
    let asset: PHAsset
    let caption: MomentCaption
    let service: PhotoLibraryService

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var showShare = false

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if let fullImage {
                    GeometryReader { geo in
                        let cardWidth = min(geo.size.width - 36, 460)
                        ScrollView(.vertical, showsIndicators: false) {
                            ShareableCard(image: fullImage, caption: caption, width: cardWidth)
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                } else {
                    ProgressView().tint(.white)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 18)
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showShare) {
            PhotoShareView(asset: asset, caption: caption, service: service)
        }
    }

    private var backdrop: some View {
        let base = fullImage?.averageColor ?? Color(.systemGray)
        return LinearGradient(
            colors: [base.opacity(0.85), .black],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(Color.black.opacity(0.25))
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Button {
                showShare = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .disabled(fullImage == nil)
        }
        .padding(.top, 8)
    }

    private func load() {
        service.requestImage(for: asset, targetSize: CGSize(width: 1400, height: 1750)) { image in
            withAnimation { self.fullImage = image }
        }
    }
}
