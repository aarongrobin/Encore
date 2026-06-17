import SwiftUI

/// Toggle the daily reminder and pick the exact time (hour/minute).
struct ReminderSettingsView: View {
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var enabled: Bool
    @State private var time: Date

    init(service: PhotoLibraryService) {
        self.service = service
        _enabled = State(initialValue: PreferenceStore.shared.dailyReminderEnabled)
        _time = State(initialValue: PreferenceStore.shared.reminderTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $enabled)
                    if enabled {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("A gentle nudge each day to look back at your memories from this date. It tells you how many you have, and never sends an empty reminder.")
                }
            }
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: enabled) { _, _ in apply() }
            .onChange(of: time) { _, _ in apply() }
        }
    }

    private func apply() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        service.setReminder(enabled: enabled, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
    }
}
