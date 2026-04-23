import SwiftUI

/// A pixel-honest mock of the expanded iOS notification YATA sends when a
/// task reminder fires. Used in two places:
///
/// - `NotificationPrimerSheet` — shown the first time a user saves a
///   reminder, before the OS permission prompt, so they know what they're
///   agreeing to.
/// - `SettingsView` → Notifications section — always-available reference
///   so users can see the feature even before engaging with it.
///
/// The content mirrors `NotificationScheduler.scheduleReminder`:
/// `title` is the task title, `subtitle` is "<Priority> priority", and the
/// action row matches the labels registered in `AppDelegate`
/// (`Done` / `30 min` / `Tomorrow`). If those labels ever diverge, update
/// both places — the whole point of this card is honesty.
struct NotificationPreviewCard: View {
    /// The example task title shown in the mock. Kept short by convention.
    var taskTitle: String = "Call the plumber"
    /// The example priority shown in the subtitle.
    var priority: Priority = .high
    /// The example "body" text. Mirrors `NotificationScheduler.bodyText`'s
    /// "today" branch by default — that's the most common case users see.
    var bodyText: String = "Scheduled for today"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            actionRow("Done", systemImage: "checkmark.circle")
            Divider().opacity(0.4)
            actionRow("30 min", systemImage: "clock.arrow.circlepath")
            Divider().opacity(0.4)
            actionRow("Tomorrow", systemImage: "sun.max")
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Example notification. YATA. \(taskTitle). \(priority.label) priority. \(bodyText). Actions: Done, 30 min, Tomorrow."
        )
    }

    // MARK: - Header (app badge + title/subtitle/body)

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            appBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("YATA")
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("now")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(taskTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(priority.label) priority")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(bodyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A rounded-square stand-in for the app icon. Using an SF Symbol + the
    /// accent color avoids pulling the real icon asset into preview code —
    /// the shape and position are what users recognize as "an app's
    /// notification icon," not the exact glyph.
    private var appBadge: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: - Action row

    private func actionRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        // Non-interactive on purpose — this is a preview, not a live
        // notification. Tapping here in the primer sheet or settings
        // shouldn't do anything.
        .allowsHitTesting(false)
    }
}

// MARK: - Preview

#Preview("Light") {
    NotificationPreviewCard()
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Dark") {
    NotificationPreviewCard(taskTitle: "Submit expenses", priority: .medium)
        .padding()
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.dark)
}
