import Foundation
import Photos
import Vision
import UIKit

/// The result of scoring one photo for "is this worth resurfacing?"
struct PhotoScore {
    let score: Double        // 0...1, higher = more interesting
    let isScreenshot: Bool
    let reason: String?      // human-readable why-it-might-be-hidden

    /// Default auto-hide threshold. User overrides win over this elsewhere.
    var autoHidden: Bool { score < 0.35 }
}

/// On-device "AI" that decides whether a photo is an interesting memory or
/// likely clutter (screenshots, documents, receipts, text-heavy captures).
/// Uses Apple's Vision framework — nothing leaves the device.
enum PhotoScorer {

    private static let junkLabels: Set<String> = [
        "document", "text", "paper", "screenshot", "menu", "receipt",
        "qr_code", "barcode", "website", "spreadsheet", "id_card", "envelope"
    ]
    private static let goodLabels: Set<String> = [
        "people", "person", "face", "selfie", "group", "wedding", "party",
        "beach", "mountain", "sunset", "landscape", "food", "dog", "cat",
        "animal", "flower", "travel", "city", "nature", "baby", "child", "outdoor"
    ]

    static func score(asset: PHAsset, image: UIImage, completion: @escaping (PhotoScore) -> Void) {
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        if isScreenshot {
            completion(PhotoScore(score: 0.0, isScreenshot: true, reason: "Screenshot"))
            return
        }
        guard let cg = image.cgImage else {
            completion(PhotoScore(score: 0.5, isScreenshot: false, reason: nil))
            return
        }

        var score = 0.5
        var reason: String?

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast

        do {
            try handler.perform([classify, faces, text])
        } catch {
            completion(PhotoScore(score: 0.5, isScreenshot: false, reason: nil))
            return
        }

        // Scene classification
        if let results = classify.results {
            for obs in results.prefix(6) where obs.confidence > 0.4 {
                let id = obs.identifier.lowercased()
                if junkLabels.contains(where: { id.contains($0) }) {
                    score -= 0.4
                    reason = "Looks like a document or screen capture"
                }
                if goodLabels.contains(where: { id.contains($0) }) {
                    score += 0.2
                }
            }
        }

        // Faces are a strong "real memory" signal
        if let faceResults = faces.results, !faceResults.isEmpty {
            score += 0.25
        }

        // Lots of text usually means a meme, receipt, or screenshot of something
        if let textResults = text.results, textResults.count > 12 {
            score -= 0.3
            if reason == nil { reason = "Mostly text" }
        }

        score = min(max(score, 0), 1)
        let finalReason = score < 0.35 ? (reason ?? "Probably not a keeper") : nil
        completion(PhotoScore(score: score, isScreenshot: false, reason: finalReason))
    }
}
