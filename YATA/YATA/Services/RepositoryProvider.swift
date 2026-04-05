import Foundation
import SwiftData

@Observable
@MainActor
final class RepositoryProvider {
    private(set) var todoRepository: any TodoRepository
    private(set) var repeatingRepository: any RepeatingRepository
    private(set) var syncEngine: SyncEngine?
    private(set) var mutationLogger: MutationLogger?

    var isClientMode: Bool {
        UserDefaults.standard.string(forKey: "serverMode") == "client"
    }

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container

        let mode = UserDefaults.standard.string(forKey: "serverMode") ?? "local"
        if mode == "client",
           let urlString = KeychainHelper.loadString(forKey: "yata_server_url"),
           let serverURL = URL(string: urlString),
           let token = KeychainHelper.loadString(forKey: "yata_api_token") {
            let localTodo = LocalTodoRepository(modelContainer: container)
            let localRepeating = LocalRepeatingRepository(modelContainer: container)
            let logger = MutationLogger(modelContext: ModelContext(container))
            let apiClient = APIClient(serverURL: serverURL, token: token)
            let engine = SyncEngine(
                apiClient: apiClient,
                mutationLogger: logger,
                modelContext: ModelContext(container)
            )
            let caching = CachingRepository(local: localTodo, localRepeating: localRepeating, logger: logger)
            self.todoRepository = caching
            self.repeatingRepository = caching
            self.mutationLogger = logger
            self.syncEngine = engine
        } else {
            self.todoRepository = LocalTodoRepository(modelContainer: container)
            self.repeatingRepository = LocalRepeatingRepository(modelContainer: container)
            self.syncEngine = nil
            self.mutationLogger = nil
        }
    }

    func switchToLocal() {
        UserDefaults.standard.set("local", forKey: "serverMode")
        todoRepository = LocalTodoRepository(modelContainer: container)
        repeatingRepository = LocalRepeatingRepository(modelContainer: container)
        syncEngine = nil
        mutationLogger = nil
    }

    func switchToClient(serverURL: URL, token: String) {
        KeychainHelper.saveString(serverURL.absoluteString, forKey: "yata_server_url")
        KeychainHelper.saveString(token, forKey: "yata_api_token")
        UserDefaults.standard.set("client", forKey: "serverMode")

        let localTodo = LocalTodoRepository(modelContainer: container)
        let localRepeating = LocalRepeatingRepository(modelContainer: container)
        let logger = MutationLogger(modelContext: ModelContext(container))
        let apiClient = APIClient(serverURL: serverURL, token: token)
        let engine = SyncEngine(
            apiClient: apiClient,
            mutationLogger: logger,
            modelContext: ModelContext(container)
        )
        let caching = CachingRepository(local: localTodo, localRepeating: localRepeating, logger: logger)
        todoRepository = caching
        repeatingRepository = caching
        mutationLogger = logger
        syncEngine = engine
    }

    func disconnect() async {
        // Pull latest server state before disconnecting
        try? await syncEngine?.fullSync()
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)

        // Clear pending mutations
        if let logger = mutationLogger {
            if let mutations = try? logger.pendingMutations() {
                for mutation in mutations {
                    try? logger.deleteMutation(mutation)
                }
            }
        }
        KeychainHelper.delete(key: "yata_api_token")
        KeychainHelper.delete(key: "yata_server_url")
        UserDefaults.standard.removeObject(forKey: "yata_lastSyncTimestamp")
        switchToLocal()
    }

    func pendingMutationCount() -> Int {
        guard let logger = mutationLogger else { return 0 }
        return (try? logger.pendingMutations().count) ?? 0
    }

    func lastSyncTime() -> String? {
        UserDefaults.standard.string(forKey: "yata_lastSyncTimestamp")
    }

    // MARK: - Preview helper

    static func preview(container: ModelContainer) -> RepositoryProvider {
        RepositoryProvider(container: container)
    }
}
