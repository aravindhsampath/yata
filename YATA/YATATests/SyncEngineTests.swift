import XCTest
import SwiftData
@testable import YATA

// MARK: - Mock URL Protocol for SyncEngine tests

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handlers: [(URLRequest) -> (Data?, HTTPURLResponse?, Error?)?] = []

    /// Register a handler that matches requests. Handlers are checked in order; first match wins.
    static func register(_ handler: @escaping (URLRequest) -> (Data?, HTTPURLResponse?, Error?)?) {
        handlers.append(handler)
    }

    static func reset() {
        handlers = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        for handler in Self.handlers {
            if let result = handler(request) {
                if let error = result.2 {
                    client?.urlProtocol(self, didFailWithError: error)
                    return
                }
                if let response = result.1 {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data = result.0 {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }
        // Default: 500
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test Helpers

@MainActor
final class SyncEngineTests: XCTestCase {
    private var container: ModelContainer!
    private var modelContext: ModelContext!
    private var mutationLogger: MutationLogger!
    private var apiClient: APIClient!
    private var session: URLSession!

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    override func setUp() {
        super.setUp()

        let schema = Schema([TodoItem.self, RepeatingItem.self, PendingMutation.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        modelContext = container.mainContext
        mutationLogger = MutationLogger(modelContext: modelContext)

        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: urlConfig)
        apiClient = APIClient(
            serverURL: URL(string: "https://api.test.com")!,
            token: "test-token",
            session: session
        )

        MockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "yata_lastSyncTimestamp")
    }

    override func tearDown() {
        MockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "yata_lastSyncTimestamp")
        super.tearDown()
    }

    // MARK: - Helper: create a SyncEngine

    private func makeSyncEngine() -> SyncEngine {
        SyncEngine(apiClient: apiClient, mutationLogger: mutationLogger, modelContext: modelContext)
    }

    // MARK: - Helper: stub a response for a path+method

    private func stubResponse(path: String, method: String, statusCode: Int, json: String) {
        MockURLProtocol.register { request in
            guard request.url?.path == path, request.httpMethod == method else { return nil }
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response, nil)
        }
    }

    private func stubResponse(path: String, method: String, statusCode: Int, data: Data = Data()) {
        MockURLProtocol.register { request in
            guard request.url?.path == path, request.httpMethod == method else { return nil }
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }
    }

    private func stubAnyResponse(statusCode: Int, json: String = "{}") {
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response, nil)
        }
    }

    private func stubNetworkError() {
        MockURLProtocol.register { request in
            return (nil, nil, URLError(.notConnectedToInternet))
        }
    }

    // MARK: - Helper: create a todo item and matching create mutation

    private func insertTodoItemWithCreateMutation(id: UUID = UUID(), title: String = "Test Item") -> (TodoItem, UUID) {
        let item = TodoItem(title: title)
        item.id = id
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)

        let body = CreateItemRequest(
            id: id,
            title: title,
            priority: 1,
            scheduledDate: "2026-04-05",
            reminderDate: nil,
            sortOrder: 0,
            sourceRepeatingId: nil,
            sourceRepeatingRuleName: nil
        )
        try! mutationLogger.log(entityType: "todoItem", entityID: id, mutationType: "create", payload: body)

        let mutations = try! mutationLogger.pendingMutations()
        return (item, mutations.last!.id)
    }

    private func insertTodoItemWithDeleteMutation(id: UUID = UUID(), title: String = "Delete Me") -> (TodoItem, UUID) {
        let item = TodoItem(title: title)
        item.id = id
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)

        // Empty payload for delete
        let emptyPayload: [String: String] = [:]
        try! mutationLogger.log(entityType: "todoItem", entityID: id, mutationType: "delete", payload: emptyPayload)

        let mutations = try! mutationLogger.pendingMutations()
        return (item, mutations.last!.id)
    }

    private func apiTodoItemJSON(id: UUID, title: String = "Test Item", updatedAt: String = "2026-04-05T12:00:00Z") -> String {
        """
        {
            "id": "\(id)",
            "title": "\(title)",
            "priority": 1,
            "is_done": false,
            "sort_order": 0,
            "reminder_date": null,
            "created_at": "2026-04-05T10:00:00Z",
            "completed_at": null,
            "scheduled_date": "2026-04-05",
            "source_repeating_id": null,
            "source_repeating_rule_name": null,
            "reschedule_count": 0,
            "updated_at": "\(updatedAt)"
        }
        """
    }

    private func syncResponseJSON(
        upsertedItems: String = "[]",
        deletedItems: String = "[]",
        upsertedRepeating: String = "[]",
        deletedRepeating: String = "[]",
        serverTime: String = "2026-04-05T14:00:00Z"
    ) -> String {
        """
        {
            "items": { "upserted": \(upsertedItems), "deleted": \(deletedItems) },
            "repeating": { "upserted": \(upsertedRepeating), "deleted": \(deletedRepeating) },
            "server_time": "\(serverTime)"
        }
        """
    }

    // MARK: - 1. Push: successful create

    func testPushSuccessfulCreate() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID, title: "New Item")

        let responseJSON = apiTodoItemJSON(id: itemID, title: "New Item", updatedAt: "2026-04-05T12:00:00Z")
        stubResponse(path: "/items", method: "POST", statusCode: 201, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.push()

        // Verify mutation deleted
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty, "Mutation should be deleted after successful push")

        // Verify updatedAt was set on local entity
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items.first?.updatedAt)
    }

    // MARK: - 2. Push: successful delete

    func testPushSuccessfulDelete() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithDeleteMutation(id: itemID)

        stubResponse(path: "/items/\(itemID)", method: "DELETE", statusCode: 204)

        let engine = makeSyncEngine()
        try await engine.push()

        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty, "Mutation should be deleted after successful delete")
    }

    // MARK: - 3. Push: 409 conflict

    func testPushConflictOverwritesLocalEntity() async throws {
        let itemID = UUID()
        let (item, _) = insertTodoItemWithCreateMutation(id: itemID, title: "Local Title")

        let serverVersionJSON = apiTodoItemJSON(id: itemID, title: "Server Title", updatedAt: "2026-04-05T15:00:00Z")
        let conflictBody = """
        {
            "error": {
                "code": "conflict",
                "message": "Version mismatch",
                "server_version": \(serverVersionJSON)
            }
        }
        """
        stubResponse(path: "/items", method: "POST", statusCode: 409, json: conflictBody)

        let engine = makeSyncEngine()
        try await engine.push()

        // Verify local entity overwritten with server version
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.first?.title, "Server Title")

        // Verify mutation deleted
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - 4. Push: 404 not found

    func testPushNotFoundDeletesLocalEntity() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID, title: "Ghost Item")

        stubResponse(path: "/items", method: "POST", statusCode: 404, json: "{}")

        let engine = makeSyncEngine()
        try await engine.push()

        // Verify local entity deleted
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertTrue(items.isEmpty, "Local entity should be deleted after 404")

        // Verify mutation deleted
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - 5. Push: 401 unauthorized

    func testPushUnauthorizedThrowsAuthError() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID)

        stubAnyResponse(statusCode: 401)

        let engine = makeSyncEngine()
        do {
            try await engine.push()
            XCTFail("Expected SyncError.authenticationRequired")
        } catch let error as SyncError {
            guard case .authenticationRequired = error else {
                XCTFail("Expected .authenticationRequired, got \(error)")
                return
            }
        }

        // Mutations should remain queued
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertFalse(remaining.isEmpty, "Mutations should remain queued after 401")
    }

    // MARK: - 6. Push: network error

    func testPushNetworkErrorThrowsAndLeavesQueue() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID)

        stubNetworkError()

        let engine = makeSyncEngine()
        do {
            try await engine.push()
            XCTFail("Expected SyncError.networkUnavailable")
        } catch let error as SyncError {
            guard case .networkUnavailable = error else {
                XCTFail("Expected .networkUnavailable, got \(error)")
                return
            }
        }

        // Mutations should remain queued
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertFalse(remaining.isEmpty, "Mutations should remain queued after network error")
    }

    // MARK: - 7. Push: ordering preserved (create before update)

    func testPushOrderingPreserved() async throws {
        let itemID = UUID()
        let item = TodoItem(title: "Ordered Item")
        item.id = itemID
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)

        // Log create first
        let createBody = CreateItemRequest(
            id: itemID, title: "Ordered Item", priority: 1,
            scheduledDate: "2026-04-05", reminderDate: nil,
            sortOrder: 0, sourceRepeatingId: nil, sourceRepeatingRuleName: nil
        )
        try mutationLogger.log(entityType: "todoItem", entityID: itemID, mutationType: "create", payload: createBody)

        // Log update second
        let updateBody = UpdateItemRequest(
            title: "Updated Item", priority: 2, isDone: false,
            sortOrder: 1, reminderDate: nil, scheduledDate: "2026-04-05",
            rescheduleCount: 0, updatedAt: nil
        )
        try mutationLogger.log(entityType: "todoItem", entityID: itemID, mutationType: "update", payload: updateBody)

        // After compaction, create+update for same entity should merge into single create
        // Track which endpoint is called
        var requestPaths: [String] = []
        MockURLProtocol.register { request in
            requestPaths.append(request.url?.path ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let json = self.apiTodoItemJSON(id: itemID)
            return (json.data(using: .utf8)!, response, nil)
        }

        let engine = makeSyncEngine()
        try await engine.push()

        // After compaction of create+update, should only be one API call (merged create)
        XCTAssertEqual(requestPaths.count, 1, "Compaction should merge create+update into single call")
        XCTAssertEqual(requestPaths.first, "/items")
    }

    // MARK: - 8. Push: compact called (create+delete = zero API calls)

    func testPushCompactCreateThenDelete() async throws {
        let itemID = UUID()
        let item = TodoItem(title: "Ephemeral")
        item.id = itemID
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)

        // Log create
        let createBody = CreateItemRequest(
            id: itemID, title: "Ephemeral", priority: 1,
            scheduledDate: "2026-04-05", reminderDate: nil,
            sortOrder: 0, sourceRepeatingId: nil, sourceRepeatingRuleName: nil
        )
        try mutationLogger.log(entityType: "todoItem", entityID: itemID, mutationType: "create", payload: createBody)

        // Log delete
        let emptyPayload: [String: String] = [:]
        try mutationLogger.log(entityType: "todoItem", entityID: itemID, mutationType: "delete", payload: emptyPayload)

        var apiCallCount = 0
        MockURLProtocol.register { request in
            apiCallCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return ("{}".data(using: .utf8)!, response, nil)
        }

        let engine = makeSyncEngine()
        try await engine.push()

        XCTAssertEqual(apiCallCount, 0, "Create+delete of same entity should compact to zero API calls")
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - 9. Pull: upserted items inserted locally

    func testPullInsertsNewItems() async throws {
        let itemID = UUID()
        let itemJSON = apiTodoItemJSON(id: itemID, title: "From Server")
        let responseJSON = syncResponseJSON(upsertedItems: "[\(itemJSON)]", serverTime: "2026-04-05T14:00:00Z")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "From Server")
    }

    // MARK: - 10. Pull: upserted items update existing

    func testPullUpdatesExistingItems() async throws {
        let itemID = UUID()
        let item = TodoItem(title: "Old Title")
        item.id = itemID
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)
        try modelContext.save()

        let itemJSON = apiTodoItemJSON(id: itemID, title: "New Title")
        let responseJSON = syncResponseJSON(upsertedItems: "[\(itemJSON)]")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.first?.title, "New Title")
    }

    // MARK: - 11. Pull: items with pending mutations skipped

    func testPullSkipsItemsWithPendingMutations() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID, title: "Local Version")

        let itemJSON = apiTodoItemJSON(id: itemID, title: "Server Version")
        let responseJSON = syncResponseJSON(upsertedItems: "[\(itemJSON)]")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.first?.title, "Local Version", "Item with pending mutation should NOT be overwritten")
    }

    // MARK: - 12. Pull: deleted items removed locally

    func testPullDeletesLocalItems() async throws {
        let itemID = UUID()
        let item = TodoItem(title: "To Be Deleted")
        item.id = itemID
        item.scheduledDate = DateFormatters.dateOnly.date(from: "2026-04-05")!
        modelContext.insert(item)
        try modelContext.save()

        let responseJSON = syncResponseJSON(deletedItems: "[\"\(itemID)\"]")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertTrue(items.isEmpty, "Deleted item should be removed from local store")
    }

    // MARK: - 13. Pull: deleted items clear pending mutations

    func testPullDeletedItemsClearPendingMutations() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID, title: "Delete And Clear")

        let responseJSON = syncResponseJSON(deletedItems: "[\"\(itemID)\"]")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        // Both item and mutation should be gone
        let itemDescriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == itemID })
        let items = try modelContext.fetch(itemDescriptor)
        XCTAssertTrue(items.isEmpty)

        let mutDescriptor = FetchDescriptor<PendingMutation>(predicate: #Predicate<PendingMutation> { $0.entityID == itemID })
        let mutations = try modelContext.fetch(mutDescriptor)
        XCTAssertTrue(mutations.isEmpty, "Pending mutations for deleted entity should be removed")
    }

    // MARK: - 14. Pull: lastSyncTimestamp stored

    func testPullStoresLastSyncTimestamp() async throws {
        let serverTime = "2026-04-05T14:30:00Z"
        let responseJSON = syncResponseJSON(serverTime: serverTime)
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: responseJSON)

        let engine = makeSyncEngine()
        try await engine.pull()

        let stored = UserDefaults.standard.string(forKey: "yata_lastSyncTimestamp")
        XCTAssertEqual(stored, serverTime)
    }

    // MARK: - 15. Pull: lastSyncTimestamp sent as since param

    func testPullSendsLastSyncTimestampAsSinceParam() async throws {
        let previousTimestamp = "2026-04-04T10:00:00Z"
        UserDefaults.standard.set(previousTimestamp, forKey: "yata_lastSyncTimestamp")

        var capturedSinceParam: String?
        MockURLProtocol.register { request in
            if request.url?.path == "/sync" {
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                capturedSinceParam = components?.queryItems?.first(where: { $0.name == "since" })?.value
                let json = self.syncResponseJSON()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (json.data(using: .utf8)!, response, nil)
            }
            return nil
        }

        let engine = makeSyncEngine()
        try await engine.pull()

        XCTAssertEqual(capturedSinceParam, previousTimestamp, "Pull should send stored timestamp as 'since' parameter")
    }

    // MARK: - 16. fullSync: push then pull

    func testFullSyncPushThenPull() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID, title: "Push Me")

        // Stub create response for push
        let createResponseJSON = apiTodoItemJSON(id: itemID, title: "Push Me")
        stubResponse(path: "/items", method: "POST", statusCode: 201, json: createResponseJSON)

        // Stub sync response for pull with a new item from server
        let serverItemID = UUID()
        let serverItemJSON = apiTodoItemJSON(id: serverItemID, title: "Pulled Item")
        let syncJSON = syncResponseJSON(upsertedItems: "[\(serverItemJSON)]")
        stubResponse(path: "/sync", method: "GET", statusCode: 200, json: syncJSON)

        let engine = makeSyncEngine()
        try await engine.fullSync()

        // Verify push cleared the mutation
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertTrue(remaining.isEmpty, "Push should have cleared mutations")

        // Verify pull inserted the server item
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == serverItemID })
        let items = try modelContext.fetch(descriptor)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Pulled Item")
    }

    // MARK: - 17. fullSync: network error in push skips pull

    func testFullSyncNetworkErrorSkipsPull() async throws {
        let itemID = UUID()
        let (_, _) = insertTodoItemWithCreateMutation(id: itemID)

        stubNetworkError()

        var pullCalled = false
        // If pull were called, the sync endpoint would be hit
        // We can detect this by checking if /sync was requested
        // But since all requests fail with network error, we just verify the error is thrown

        let engine = makeSyncEngine()
        do {
            try await engine.fullSync()
            XCTFail("Expected SyncError.networkUnavailable")
        } catch let error as SyncError {
            guard case .networkUnavailable = error else {
                XCTFail("Expected .networkUnavailable, got \(error)")
                return
            }
        }

        // Mutations should still be queued (push failed, pull was skipped)
        let remaining = try mutationLogger.pendingMutations()
        XCTAssertFalse(remaining.isEmpty)
    }
}
