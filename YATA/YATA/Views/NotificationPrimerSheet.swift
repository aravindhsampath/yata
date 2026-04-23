import SwiftUI

/// Shown the first time a user saves a reminder and the system permission
/// status is `.notDetermined`. Replaces a plain `.alert` with a richer
/// surface that includes a `NotificationPreviewCard` — the user sees
/// exactly what YATA's reminders look like *before* being asked to grant
/// permission.
///
/// Flow:
/// - **Enable Reminders** → triggers the real OS permission prompt via
///   `NotificationPermissionManager.requestPermission()`. Regardless of
///   the user's answer in that system alert, `onDecision` is called so
///   the parent view can commit the save. If they allowed, the reminder
///   schedules; if they denied, `reminderDate` is still stored and we'll
///   re-ask next time (a new instance — status flips to `.denied` so
///   this sheet is skipped in favor of the inline "Notifications are off"
///   banner).
/// - **Not Now** → `onDecision` is called without requesting permission,
///   leaving status at `.notDetermined`. The reminder is still saved;
///   the user will see this primer again next time they set one. That's
///   by design — the point of JIT permission is to ask only when the
///   user has signalled intent.
///
/// This sheet deliberately does not show the "Notifications are off —
/// Open Settings" banner: it's only presented when status is
/// `.notDetermined`, so there's nothing for the user to recover from yet.
struct NotificationPrimerSheet: View {
    let permissionManager: NotificationPermissionManager
    let taskTitle: String
    let priority: Priority
    /// Called after the user picks Enable or Not Now. Parent should
    /// dismiss this sheet and proceed with its save flow.
    let onDecision: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    NotificationPreviewCard(
                        taskTitle: taskTitle,
                        priority: priority
                    )
                    explanation
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("Turn on reminders?")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRequesting)
        }
        .presentationDetents([.large])
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("YATA will nudge you at the right time.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            bullet(
                icon: "clock",
                text: "Reminders fire at the exact time you pick — not before, not after."
            )
            bullet(
                icon: "hand.tap",
                text: "Act on a reminder without opening the app: mark it done, snooze 30 minutes, or push it to tomorrow."
            )
            bullet(
                icon: "lock.shield",
                text: "Reminders stay on this device. YATA doesn't send push notifications from a server."
            )
        }
        .padding(.top, 4)
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button {
                Task { await enable() }
            } label: {
                HStack {
                    if isRequesting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Enable Reminders")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)

            Button("Not Now") {
                onDecision()
                dismiss()
            }
            .disabled(isRequesting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Actions

    private func enable() async {
        isRequesting = true
        _ = await permissionManager.requestPermission()
        isRequesting = false
        onDecision()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    Color(.systemGroupedBackground)
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            NotificationPrimerSheet(
                permissionManager: NotificationPermissionManager(),
                taskTitle: "Call the plumber",
                priority: .high,
                onDecision: {}
            )
        }
}
