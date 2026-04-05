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
    @State private var networkMonitor = NetworkMonitor()

    init() {
        let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self, PendingMutation.self)
        self.container = container
        self._repositoryProvider = State(initialValue: RepositoryProvider(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(repositoryProvider)
                .environment(networkMonitor)
                .preferredColorScheme(resolvedColorScheme)
                .onAppear {
                    appDelegate.modelContainer = container
                    appDelegate.repositoryProvider = repositoryProvider
                    networkMonitor.onReconnect = { [repositoryProvider] in
                        guard repositoryProvider.isClientMode else { return }
                        try? await repositoryProvider.syncEngine?.fullSync()
                        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
                    }
                    networkMonitor.start()
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
                    } else if newPhase == .background && repositoryProvider.isClientMode {
                        appDelegate.scheduleBackgroundSync()
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
