import SwiftUI
import SwiftData
import UserNotifications

@main
struct YATAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var repositoryProvider: RepositoryProvider

    init() {
        let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self, PendingMutation.self)
        self.container = container
        self._repositoryProvider = State(initialValue: RepositoryProvider(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(repositoryProvider)
                .preferredColorScheme(resolvedColorScheme)
                .onAppear {
                    appDelegate.modelContainer = container
                    appDelegate.repositoryProvider = repositoryProvider
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        UNUserNotificationCenter.current().setBadgeCount(0)
                        if repositoryProvider.isClientMode {
                            Task {
                                try? await repositoryProvider.syncEngine?.fullSync()
                                NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
                            }
                        }
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
