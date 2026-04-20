import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = AppTab.home
    @State private var sessionExpiredAlert = false
    @Environment(RepositoryProvider.self) private var repositoryProvider

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView()
            }
            Tab("Repeating", systemImage: "repeat", value: .repeating) {
                RepeatingView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .yataSessionExpired)) { _ in
            // Dedup: concurrent writes can 401 simultaneously; don't stack
            // alerts or double-disconnect.
            guard !sessionExpiredAlert, repositoryProvider.isClientMode else { return }
            Task {
                await repositoryProvider.disconnect()
                sessionExpiredAlert = true
                selectedTab = .settings
            }
        }
        .alert("Signed out", isPresented: $sessionExpiredAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your session expired. Sign in again from Settings to keep syncing.")
        }
    }
}

#Preview {
    let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self, PendingMutation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    ContentView()
        .environment(RepositoryProvider.preview(container: container))
        .modelContainer(container)
}
