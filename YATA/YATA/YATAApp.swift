import SwiftUI
import SwiftData
import UserNotifications

@main
struct YATAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    /// Tracks whether the SwiftData store opened successfully. We
    /// can't `try!` the load any more — corrupt stores and failed
    /// migrations are real failure modes that used to crash the app
    /// silently on cold launch with no recovery path. Now we hold
    /// either a live container or the underlying error, and the
    /// scene picks which surface to render.
    ///
    /// Mutable state lives behind `@State` so the "Try Again" /
    /// "Reset Local Data" buttons in `DataStoreErrorView` can
    /// re-attempt the load and swap the case.
    @State private var loadState: DataStoreLoadState

    /// `RepositoryProvider` requires a live container, so it's only
    /// constructed once we have one. Optional until then.
    @State private var repositoryProvider: RepositoryProvider?

    @State private var networkMonitor = NetworkMonitor()

    private let loader = DataStoreLoader()

    init() {
        let initial: DataStoreLoadState
        do {
            let container = try DataStoreLoader().load()
            initial = .loaded(container)
        } catch {
            initial = .failed(error)
        }
        _loadState = State(initialValue: initial)
        _repositoryProvider = State(initialValue: nil)
    }

    var body: some Scene {
        WindowGroup {
            switch loadState {
            case .loaded(let container):
                contentScene(container: container)
            case .failed(let error):
                DataStoreErrorView(
                    errorDescription: errorDetail(error),
                    onRetry: retryLoad,
                    onReset: resetAndLoad
                )
                .preferredColorScheme(resolvedColorScheme)
            }
        }
    }

    // MARK: - Content (happy path)

    @ViewBuilder
    private func contentScene(container: ModelContainer) -> some View {
        // The provider is constructed lazily on first appearance
        // because @State init can't take dependencies on other
        // @State values. By the time `.onAppear` fires we always
        // have a container.
        ContentView()
            .environment(repositoryProvider ?? makeProvider(container: container))
            .environment(networkMonitor)
            .preferredColorScheme(resolvedColorScheme)
            .modelContainer(container)
            .onAppear {
                if repositoryProvider == nil {
                    repositoryProvider = makeProvider(container: container)
                }
                guard let provider = repositoryProvider else { return }
                appDelegate.modelContainer = container
                appDelegate.repositoryProvider = provider
                networkMonitor.onReconnect = { [provider] in
                    guard provider.isClientMode else { return }
                    try? await provider.syncEngine?.syncIfStale()
                    NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
                }
                networkMonitor.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    UNUserNotificationCenter.current().setBadgeCount(0)
                    if let provider = repositoryProvider, provider.isClientMode {
                        Task {
                            try? await provider.syncEngine?.syncIfStale()
                            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
                        }
                    }
                } else if newPhase == .background,
                          let provider = repositoryProvider,
                          provider.isClientMode {
                    appDelegate.scheduleBackgroundSync()
                }
            }
    }

    private func makeProvider(container: ModelContainer) -> RepositoryProvider {
        RepositoryProvider(container: container)
    }

    // MARK: - Recovery actions

    /// Re-attempt the load without deleting anything. If the failure
    /// was transient (disk pressure / low memory) this clears it; if
    /// not, the error view stays.
    private func retryLoad() {
        do {
            let container = try loader.load()
            loadState = .loaded(container)
        } catch {
            loadState = .failed(error)
        }
    }

    /// Nuke the on-disk store + sidecars and create a fresh one.
    /// Destructive — DataStoreErrorView's confirmation dialog
    /// already gated this call.
    private func resetAndLoad() {
        do {
            let container = try loader.resetAndLoad()
            loadState = .loaded(container)
        } catch {
            // Reset failed too. Surface the new error; user can
            // file a bug at this point, or reinstall the app.
            loadState = .failed(error)
        }
    }

    // MARK: - Helpers

    private var resolvedColorScheme: ColorScheme? {
        switch ColorSchemePreference(rawValue: colorSchemePreference) {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }

    /// SwiftData errors include a `localizedDescription` that's
    /// usually informative; we also include the debug description
    /// for the rare cases where it's not.
    private func errorDetail(_ error: Error) -> String {
        let desc = error.localizedDescription
        let debug = String(reflecting: error)
        return desc == debug ? desc : "\(desc)\n\n\(debug)"
    }
}

/// State machine for the SwiftData container lifecycle. Lives at
/// file scope so unit tests can construct values without poking at
/// `YATAApp` internals.
enum DataStoreLoadState {
    case loaded(ModelContainer)
    case failed(Error)
}
