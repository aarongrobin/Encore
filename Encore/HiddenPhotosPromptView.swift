import SwiftUI

/// What the hidden-photos sheet is saying (build 48, MAR-47): the one-time intro right after the
/// reminder choice, or a check-in at day 9 / 36 / 72 that reminds people Encore is still setting
/// photos aside.
struct HiddenPhotosPrompt: Identifiable {
    enum Kind { case intro, checkIn }
    let id = UUID()
    let kind: Kind
    let count: Int
}

/// A half-height sheet that tells people Encore hides clutter and offers the review. Same visual
/// language as `NotificationOptInView` so the two first-run sheets read as one sequence.
struct HiddenPhotosPromptView: View {
    let prompt: HiddenPhotosPrompt
    /// Called when the user chooses to review. The host opens `HiddenPhotosView` after this
    /// sheet has dismissed.
    let onReview: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var noun: String { prompt.count == 1 ? "photo" : "photos" }

    private var title: String {
        switch prompt.kind {
        case .intro:   return prompt.count == 1 ? "We set a photo aside" : "We set a few photos aside"
        case .checkIn: return "Still tidying your memories"
        }
    }

    private var message: String {
        switch prompt.kind {
        case .intro:
            return "Encore hides screenshots, documents, and clutter so your memories stay clean. \(prompt.count) \(noun) from this day \(prompt.count == 1 ? "is" : "are") set aside. The eye icon at the top always shows the count, and you can bring any of them back."
        case .checkIn:
            return "Encore keeps setting aside screenshots and documents each day. \(prompt.count) \(noun) \(prompt.count == 1 ? "is" : "are") hidden today. Take a look if you want any of them back."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            VStack(spacing: 14) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Button {
                    dismiss()
                    onReview()
                } label: {
                    Text("Review \(prompt.count) hidden \(noun)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                }

                Button { dismiss() } label: {
                    Text("Got it")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}
