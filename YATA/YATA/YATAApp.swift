import SwiftUI
import SwiftData

@main
struct YATAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue

    private let container: ModelContainer

    init() {
        let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self)
        self.container = container
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(resolvedColorScheme)
                .onAppear {
                    appDelegate.modelContainer = container
                }
        }
        .modelContainer(container)
    }

    private var resolvedColorScheme: ColorScheme? {
        switch ColorSchemePreference(rawValue: colorSchemePreference) {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }
}
