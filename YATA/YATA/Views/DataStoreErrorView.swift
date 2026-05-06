import SwiftUI

/// Shown when `DataStoreLoader.load()` throws on cold launch — the
/// SwiftData store is corrupt, a migration failed, or the disk is
/// full. Replaces the previous behavior (silent crash) with a
/// surface the user can act on.
///
/// The two recovery buttons:
///
/// - **Try Again** — re-attempts the load. Useful when the failure
///   was transient (disk pressure, low memory at launch). If it
///   fails again, the same error sticks.
/// - **Reset Local Data** — deletes the store + WAL/SHM sidecars
///   and creates a fresh empty one. Destructive: any unsynced
///   changes are lost. We keep the second confirmation alert in
///   front of it so a user doesn't tap it by accident.
struct DataStoreErrorView: View {
    /// Description of what went wrong. Surfaced verbatim — the
    /// SwiftData error messages are usually informative enough that
    /// a power user can self-diagnose.
    let errorDescription: String
    /// Closure invoked when the user taps "Try Again". Should
    /// re-run `DataStoreLoader.load()` and update the parent's
    /// loadResult on success.
    let onRetry: () -> Void
    /// Closure invoked after the user confirms "Reset Local Data".
    /// Should call `DataStoreLoader.resetAndLoad()` and update the
    /// parent's loadResult.
    let onReset: () -> Void

    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .padding(.top, 64)

            Text("Local data is unavailable")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("YATA couldn't open its on-disk store. Your tasks are still safe on the server (if you've connected one). You can try again, or reset to a fresh empty store on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Surface the underlying SwiftData / FS error verbatim
            // — it's frequently informative, and we'd rather not
            // hide it from a user reading this on a forum.
            ScrollView {
                Text(errorDescription)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
            }
            .frame(maxHeight: 140)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    onRetry()
                } label: {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Text("Reset Local Data")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .alert("Reset local data?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { onReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every todo on this device. If you're connected to a YATA server, your tasks are still safe there and will reappear on next sync.")
        }
    }
}

#Preview {
    DataStoreErrorView(
        errorDescription: "SwiftData failed to migrate the schema: the model graph changed since the last successful open.",
        onRetry: {},
        onReset: {}
    )
}
