import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = AppTab.home

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
    }
}

#Preview {
    let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self, PendingMutation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    ContentView()
        .environment(RepositoryProvider.preview(container: container))
        .modelContainer(container)
}
