import SwiftUI

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
    ContentView()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
