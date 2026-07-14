import SwiftUI

/// First-open opt-in for the daily reminder (build 39, MAR-45). A friendly priming screen shown
/// once after the first set of memories loads: it explains the value, offers a time (defaulting to
/// 9:00 AM but editable right here), and only triggers the system notification permission prompt if
/// the user opts in. "Not now" leaves notifications off; either choice marks the prompt as shown so
/// it never asks again.
struct NotificationOptInView: View {
    let service: PhotoLibraryService
    /// Called after the user chooses (enable or not now) so the host can dismiss.
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Defaults to the stored reminder time, which is 9:00 AM on a fresh install.
    @State private var time: Date = PreferenceStore.shared.reminderTime

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                Text("Never miss a memory")
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Get a gentle daily nudge when you have photos from this day in past years. It tells you how many, and never sends an empty reminder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            DatePicker("Reminder time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(.top, 18)

            Spacer()

            VStack(spacing: 12) {
                Button(action: enable) {
                    Text("Turn on daily reminder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                }

                Button(action: skip) {
                    Text("Not now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func enable() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        // Triggers the system notification permission prompt; persists the chosen time.
        service.setReminder(enabled: true, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
        finish()
    }

    private func skip() { finish() }

    private func finish() {
        PreferenceStore.shared.notificationPromptShown = true
        onFinish()
        dismiss()
    }
}
