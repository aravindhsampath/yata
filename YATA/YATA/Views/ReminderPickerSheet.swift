import SwiftUI
import UserNotifications

struct ReminderPickerSheet: View {
    @Binding var selectedDate: Date?
    var permissionManager: NotificationPermissionManager
    @Environment(\.dismiss) private var dismiss

    @State private var pickerDate = Date.now
    @State private var showPermissionAlert = false

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
            .alert("Enable Notifications?", isPresented: $showPermissionAlert) {
                Button("Not Now") {
                    // Save anyway without notification permission
                    commitSave()
                }
                Button("Enable") {
                    Task {
                        _ = await permissionManager.requestPermission()
                        commitSave()
                    }
                }
            } message: {
                Text("YATA needs notification permission to remind you about this task at the scheduled time.")
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
            showPermissionAlert = true
        } else {
            commitSave()
        }
    }

    private func commitSave() {
        selectedDate = pickerDate
        dismiss()
    }
}
