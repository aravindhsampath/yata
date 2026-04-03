import SwiftUI
import SwiftData

@main
struct YATAApp: App {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(resolvedColorScheme)
        }
        .modelContainer(for: [TodoItem.self, RepeatingItem.self])
    }

    private var resolvedColorScheme: ColorScheme? {
        switch ColorSchemePreference(rawValue: colorSchemePreference) {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }
}
