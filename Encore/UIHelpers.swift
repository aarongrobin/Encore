import SwiftUI
import Photos
import UIKit
import CoreImage

// MARK: - Async PhotoKit image

/// Loads a PHAsset's image asynchronously and fades it in.
///
/// `targetSize` is the desired DISPLAY size in points; the request is made at native pixel
/// resolution (`targetSize * screen scale`) so the on-screen image is crisp rather than a
/// point-sized thumbnail upscaled on a Retina display. Pass `.zero` to request the maximum
/// available resolution (used by the full-screen / hero presentations).
struct AsyncPHImage: View {
    let asset: PHAsset
    let service: PhotoLibraryService
    var targetSize = CGSize(width: 700, height: 900)
    var contentMode: ContentMode = .fill
    /// Alignment used when the image overflows its frame (e.g. .fill crop, or .fit
    /// letterbox). Default center; pass .top to keep the TOP of the photo visible.
    var alignment: Alignment = .center
    /// True for the peek + full-screen photos: requests a single high-quality delivery so the
    /// image is never shown blurry (a brief placeholder shows while it loads instead).
    var highQuality: Bool = false
    /// An already-decoded image to show IMMEDIATELY with no async load and no fade. Used by the
    /// home cover peek, whose hero is prefetched on the loading screen so the home appears with
    /// the photo already present (no white placeholder). When set, no PhotoKit request is made.
    var preloaded: UIImage? = nil

    @State private var image: UIImage?
    @State private var faded = false

    /// Request size in PIXELS. The caller's `targetSize` is in points; multiply by the screen
    /// scale so PhotoKit returns enough resolution to look sharp on Retina. `.zero` means
    /// "maximum size" — used for full-screen / hero photos that must be full resolution.
    private var pixelTargetSize: CGSize {
        let scale = UIScreen.main.scale
        // `.zero` means "screen resolution" — full screen native pixels, which is as crisp as the
        // display can show and loads far faster than the full original. Requesting the original at
        // PHImageManagerMaximumSize (with opportunistic delivery) is what left the peek blurry.
        if targetSize == .zero {
            let b = UIScreen.main.bounds.size
            return CGSize(width: b.width * scale, height: b.height * scale)
        }
        return CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
                        .clipped()
                        // Self-contained fade: the opacity is animated by THIS view's own
                        // value-scoped animation, so the load completion does not need an
                        // ancestor-propagating `withAnimation`. That keeps the parent's
                        // repeatForever idle drift (DeckHomePage) from being interrupted when
                        // the image arrives.
                        .opacity(faded ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: faded)
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                        .overlay(ProgressView())
                }
            }
        }
        .onAppear {
            // A preloaded image (home peek hero, decoded on the loading screen) shows instantly
            // with no fade so the home never flashes white. Skip the PhotoKit request entirely.
            if let preloaded {
                if image == nil {
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { image = preloaded }
                    faded = true
                }
                return
            }
            service.requestImage(for: asset, targetSize: pixelTargetSize, highQuality: highQuality) { loaded in
                guard let loaded else { return }
                // Update state with inherited animations explicitly disabled, then trigger the
                // local fade. The first assignment (placeholder swap) and any later high-quality
                // upgrade must not animate ancestor layers; only `faded` drives the visible fade.
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { self.image = loaded }
                if !faded { faded = true }
            }
        }
    }
}

// MARK: - Share sheet

/// UIKit share sheet for sharing a rendered UIImage.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Color extraction for ambient backgrounds

extension UIImage {
    /// Average color of the image, used to build a soft ambient backdrop.
    var averageColor: Color {
        guard let inputImage = CIImage(image: self) else { return Color(.systemGray5) }
        let extent = inputImage.extent
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: inputImage,
                                                 kCIInputExtentKey: CIVector(cgRect: extent)]),
              let output = filter.outputImage else { return Color(.systemGray5) }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bitmap, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: nil)
        return Color(.sRGB,
                     red: Double(bitmap[0]) / 255.0,
                     green: Double(bitmap[1]) / 255.0,
                     blue: Double(bitmap[2]) / 255.0)
    }
}
