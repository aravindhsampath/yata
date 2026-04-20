import Foundation
import SwiftData

@Observable
@MainActor
final class RepositoryProvider {
    private(set) var todoRepository: any TodoRepository
    private(set) var repeatingRepository: any RepeatingRepository
    /// Pull-only sync coordinator. Only non-nil in API (client) mode.
    private(set) var syncEngine: SyncEngine?
    /// API client for the current session. Only non-nil in API (client) mode.
    /// Exposed so non-repository flows (e.g. notification-action handlers in
    /// AppDelegate that mutate a TodoItem via their own ModelContext) can
    /// mirror the write to the server.
    private(set) var apiClient: APIClient?

    var isClientMode: Bool {
        UserDefaults.standard.string(forKey: "serverMode") == "client"
    }

    /// The username the current client-mode session is authenticated as,
    /// or nil if running in local mode.
    var connectedUsername: String? {
        guard isClientMode else { return nil }
        return KeychainHelper.loadString(forKey: "yata_username")
    }

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container

        let mode = UserDefaults.standard.string(forKey: "serverMode") ?? "local"
        if mode == "client",
           let urlString = KeychainHelper.loadString(forKey: "yata_server_url"),
           let serverURL = URL(string: urlString),
           let token = KeychainHelper.loadString(forKey: "yata_api_token") {
            // API (client) mode: write-through CachingRepository + pull-only SyncEngine.
            let localTodo = LocalTodoRepository(modelContainer: container)
            let localRepeating = LocalRepeatingRepository(modelContainer: container)
            let apiClient = APIClient(serverURL: serverURL, token: token)
            let engine = SyncEngine(apiClient: apiClient, modelContainer: container)
            let caching = CachingRepository(local: localTodo, localRepeating: localRepeating, apiClient: apiClient)
            self.todoRepository = caching
            self.repeatingRepository = caching
            self.syncEngine = engine
            self.apiClient = apiClient
        } else {
            // Local mode: plain SwiftData-backed repositories. No network.
            self.todoRepository = LocalTodoRepository(modelContainer: container)
            self.repeatingRepository = LocalRepeatingRepository(modelContainer: container)
            self.syncEngine = nil
            self.apiClient = nil
        }
    }

    func switchToLocal() {
        UserDefaults.standard.set("local", forKey: "serverMode")
        todoRepository = LocalTodoRepository(modelContainer: container)
        repeatingRepository = LocalRepeatingRepository(modelContainer: container)
        syncEngine = nil
        apiClient = nil
    }

    func switchToClient(serverURL: URL, username: String, token: String) {
        KeychainHelper.saveString(serverURL.absoluteString, forKey: "yata_server_url")
        KeychainHelper.saveString(username, forKey: "yata_username")
        KeychainHelper.saveString(token, forKey: "yata_api_token")
        UserDefaults.standard.set("client", forKey: "serverMode")

        let localTodo = LocalTodoRepository(modelContainer: container)
        let localRepeating = LocalRepeatingRepository(modelContainer: container)
        let client = APIClient(serverURL: serverURL, token: token)
        let engine = SyncEngine(apiClient: client, modelContainer: container)
        let caching = CachingRepository(local: localTodo, localRepeating: localRepeating, apiClient: client)
        todoRepository = caching
        repeatingRepository = caching
        syncEngine = engine
        apiClient = client
    }

    func disconnect() async {
        // Pull latest server state once before tearing down so the local
        // cache reflects the final server truth. Best-effort.
        try? await syncEngine?.fullSync()
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)

        KeychainHelper.delete(key: "yata_api_token")
        KeychainHelper.delete(key: "yata_server_url")
        KeychainHelper.delete(key: "yata_username")
        UserDefaults.standard.removeObject(forKey: "yata_lastSyncTimestamp")
        switchToLocal()
    }

    func lastSyncTime() -> String? {
        UserDefaults.standard.string(forKey: "yata_lastSyncTimestamp")
    }

    // MARK: - Preview helper

    static func preview(container: ModelContainer) -> RepositoryProvider {
        RepositoryProvider(container: container)
    }
}
