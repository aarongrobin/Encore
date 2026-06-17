import SwiftUI

/// First-run intro: explains the privacy model and why Encore asks for photo
/// access, before the system permission prompt appears.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Encore")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                Text("Your photos from this day, every year.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 44)

            VStack(alignment: .leading, spacing: 26) {
                point("lock.shield.fill", "Private by design",
                      "Everything happens on your device. Your photos never leave your phone — no account, no cloud, nothing uploaded.")
                point("photo.on.rectangle.angled", "Why Encore needs your photos",
                      "It reads your library only to find the photos you took on today's date in past years.")
                point("gearshape.fill", "You're always in control",
                      "Change or revoke photo access anytime in Settings, and choose to share only selected photos if you prefer.")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)

            Text("Next, iOS will ask permission to access your photos.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
