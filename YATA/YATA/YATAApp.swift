import SwiftUI
import SwiftData

@main
struct YATAApp: App {
    @AppStorage("colorScheme") private var colorSchemePreference = 0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(resolvedColorScheme)
        }
        .modelContainer(for: [TodoItem.self, RepeatingItem.self])
    }

    private var resolvedColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case 1: .light
        case 2: .dark
        default: nil
        }
    }
}
