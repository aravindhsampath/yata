import SwiftUI
import UserNotifications

struct ReminderPickerSheet: View {
    @Binding var selectedDate: Date?
    var permissionManager: NotificationPermissionManager
    /// Passed through to `NotificationPrimerSheet` so the mock reminder in
    /// the primer shows the user's actual task title instead of a generic
    /// placeholder. Optional — falls back to a neutral example for any
    /// caller that doesn't have a title handy (e.g., previews).
    var taskTitle: String = "Your task"
    @Environment(\.dismiss) private var dismiss

    @State private var pickerDate = Date.now
    /// Replaces the previous plain `.alert` with a richer primer sheet
    /// (`NotificationPrimerSheet`) that shows users exactly what YATA's
    /// reminders look like before requesting permission. Only shown when
    /// authorization status is `.notDetermined` — see `saveReminder()`.
    @State private var showPermissionPrimer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                DatePicker(
                    "Date",
                    selection: $pickerDate,
                    in: Date.now...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)

                DatePicker(
                    "Time",
                    selection: $pickerDate,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(height: 100)

                if permissionManager.authorizationStatus == .denied {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                        Text("Notifications are off.")
                            .font(.caption)
                        Button("Enable in Settings") {
                            permissionManager.openSettings()
                        }
                        .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Set Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveReminder()
                    }
                }
            }
            .sheet(isPresented: $showPermissionPrimer) {
                // Whether the user taps Enable (granting or denying the
                // real OS prompt) or Not Now, we commit the save. The
                // reminderDate is stored either way — if permission was
                // denied, `NotificationScheduler.scheduleReminder` will
                // no-op at the OS layer and the inline "Notifications
                // are off" banner (above) takes over on the next visit.
                NotificationPrimerSheet(
                    permissionManager: permissionManager,
                    taskTitle: taskTitle,
                    priority: .medium,
                    onDecision: { commitSave() }
                )
            }
        }
        .presentationDetents([.large])
        .task {
            if let selectedDate {
                pickerDate = selectedDate
            }
            await permissionManager.checkStatus()
        }
    }

    private func saveReminder() {
        if permissionManager.authorizationStatus == .notDetermined {
            showPermissionPrimer = true
        } else {
            commitSave()
        }
    }

    private func commitSave() {
        selectedDate = pickerDate
        dismiss()
    }
}
