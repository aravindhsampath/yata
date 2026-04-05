import SwiftUI
import SwiftData
import UserNotifications

@main
struct YATAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

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
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        UNUserNotificationCenter.current().setBadgeCount(0)
                    }
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
