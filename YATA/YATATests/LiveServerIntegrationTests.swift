//
// LiveServerIntegrationTests
//
// End-to-end tests that hit a real YATA backend over the network. Use this
// to catch regressions in the iOS↔Rust contract without manually tapping
// through the simulator every time.
//
// These tests are DISABLED by default — they only run when the
// `YATA_LIVE_TEST` env var is set (value truthy). Credentials come from
// env vars:
//
//     YATA_LIVE_URL       — e.g. https://yata.aravindh.net
//     YATA_LIVE_USERNAME  — e.g. aravindh
//     YATA_LIVE_PASSWORD  — the account password
//
// Cleanup: each test wipes the authenticated user's items before and
// after running. The account you point these at should be a test /
// personal account — we DELETE all todo items in it.
//
// Run from the CLI:
//
//     YATA_LIVE_TEST=1 \
//     YATA_LIVE_URL=https://yata.aravindh.net \
//     YATA_LIVE_USERNAME=aravindh \
//     YATA_LIVE_PASSWORD=... \
//       xcodebuild test \
//         -scheme YATA \
//         -sdk iphonesimulator \
//         -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//         -only-testing:YATATests/LiveServerIntegrationTests
//
// Or from Xcode: set the env vars in the scheme's Test action and run.

import XCTest
@testable import YATA

final class LiveServerIntegrationTests: XCTestCase {
    private var serverURL: URL!
    private var token: String!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YATA_LIVE_TEST"].map { !$0.isEmpty } ?? false,
            "Live integration tests are disabled. Set YATA_LIVE_TEST=1 plus YATA_LIVE_URL / YATA_LIVE_USERNAME / YATA_LIVE_PASSWORD to run."
        )
        let env = ProcessInfo.processInfo.environment
        guard
            let urlStr = env["YATA_LIVE_URL"], let url = URL(string: urlStr),
            let username = env["YATA_LIVE_USERNAME"],
            let password = env["YATA_LIVE_PASSWORD"]
        else {
            throw XCTSkip("Missing YATA_LIVE_URL / YATA_LIVE_USERNAME / YATA_LIVE_PASSWORD")
        }
        self.serverURL = url
        self.token = try await APIClient.authenticate(serverURL: url, username: username, password: password)
        try await wipeAllItems()
    }

    override func tearDown() async throws {
        // Best-effort cleanup so failed runs don't leak.
        if token != nil, serverURL != nil {
            try? await wipeAllItems()
        }
        try await super.tearDown()
    }

    // MARK: - Cleanup

    private func wipeAllItems() async throws {
        let client = APIClient(serverURL: serverURL, token: token)
        // /sync with a far-past `since` returns every item the user has.
        let sync: SyncResponse = try await client.request(.sync(since: "1970-01-01T00:00:00Z"))
        for item in sync.items.upserted {
            try await client.requestNoContent(.deleteItem(id: item.id))
        }
        for rule in sync.repeating.upserted {
            try await client.requestNoContent(.deleteRepeating(id: rule.id))
        }
    }

    // MARK: - Helpers

    private func makeClient() -> APIClient {
        APIClient(serverURL: serverURL, token: token)
    }

    /// Build a `CreateItemRequest` with sensible defaults.
    private func createRequest(
        id: UUID = UUID(),
        title: String = "integration test item",
        priority: Int = 1,
        date: String = "2026-04-20"
    ) -> CreateItemRequest {
        CreateItemRequest(
            id: id,
            title: title,
            priority: priority,
            scheduledDate: date,
            reminderDate: nil,
            sortOrder: 0,
            sourceRepeatingId: nil,
            sourceRepeatingRuleName: nil
        )
    }

    /// Build an UpdateItemRequest that echoes the server's current fields,
    /// with optional per-field overrides. Fields are `let` on the DTO so
    /// we construct a fresh value each time.
    private func updateRequest(
        from server: APITodoItem,
        title: String? = nil
    ) -> UpdateItemRequest {
        // Note: `updatedAt` is no longer a field on UpdateItemRequest —
        // server is authoritative on `updated_at` after the conflict
        // redesign (docs/conflict_resolution_redesign.md). The legacy
        // updatedAt parameter on this helper has been removed.
        UpdateItemRequest(
            title: title ?? server.title,
            priority: server.priority,
            isDone: server.isDone,
            sortOrder: server.sortOrder,
            reminderDate: server.reminderDate,
            scheduledDate: server.scheduledDate,
            rescheduleCount: server.rescheduleCount
        )
    }

    // MARK: - Tests

    /// Smoke: auth works and we can list items (empty after wipe).
    func test_authAndListEmpty() async throws {
        let client = makeClient()
        let sync: SyncResponse = try await client.request(.sync(since: "1970-01-01T00:00:00Z"))
        XCTAssertEqual(sync.items.upserted.count, 0, "wipe failed to clear items")
    }

    /// Create an item, fetch it back, verify round-trip fidelity.
    func test_createAndReadBack() async throws {
        let client = makeClient()
        let id = UUID()
        let req = createRequest(id: id, title: "first todo", priority: 2, date: "2026-04-22")
        let created: APITodoItem = try await client.request(.createItem(body: req))
        XCTAssertEqual(created.id, id)
        XCTAssertEqual(created.title, "first todo")
        XCTAssertEqual(created.priority, 2)
        XCTAssertEqual(created.scheduledDate, "2026-04-22")
        XCTAssertFalse(created.isDone)
        XCTAssertNotNil(created.updatedAt)

        let list: ItemsResponse = try await client.request(.getItems(date: "2026-04-22", priority: 2))
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items.first?.id, id)
    }

    /// Regression: PUT /items/:id with the server's exact updated_at must
    /// succeed with 200, NOT 409. This is the exact bug found on
    /// 2026-04-20 (subsec precision round-trip).
    func test_update_doesNotFalseConflict() async throws {
        let client = makeClient()
        let id = UUID()
        let created: APITodoItem = try await client.request(
            .createItem(body: createRequest(id: id, title: "to update"))
        )

        // Mutate + PUT with the server's updated_at echoed back.
        let body = updateRequest(from: created, title: "updated title")
        let updated: APITodoItem = try await client.request(.updateItem(id: id, body: body))
        XCTAssertEqual(updated.title, "updated title", "server rejected the update (likely 409)")
    }

    /// Regression: rapid back-to-back updates of the same item — the
    /// canonical "user double-taps to mark done" pattern — must all
    /// succeed against a live server. Pre-redesign, the second PUT
    /// would 409 because the server's stored `updated_at` raced ahead
    /// of the client's reconciled value. Post-redesign, the conflict
    /// check is gone (see docs/conflict_resolution_redesign.md) and
    /// every PUT succeeds.
    func test_update_rapidBackToBack_doesNotFalseConflict() async throws {
        let client = makeClient()
        let id = UUID()
        let created: APITodoItem = try await client.request(
            .createItem(body: createRequest(id: id, title: "burst"))
        )

        // Three updates in immediate succession with the same source
        // record — proves the server doesn't gate on `updated_at`.
        for i in 1...3 {
            let body = updateRequest(from: created, title: "burst \(i)")
            let updated: APITodoItem = try await client.request(.updateItem(id: id, body: body))
            XCTAssertEqual(updated.title, "burst \(i)", "PUT #\(i) was rejected — conflict check regressed?")
        }
    }

    /// Mark done → undone round trip.
    func test_markDoneThenUndone() async throws {
        let client = makeClient()
        let id = UUID()
        _ = try await client.request(.createItem(body: createRequest(id: id, title: "toggle"))) as APITodoItem

        let done: APITodoItem = try await client.request(.markDone(id: id))
        XCTAssertTrue(done.isDone)
        XCTAssertNotNil(done.completedAt)

        let undone: APITodoItem = try await client.request(
            .markUndone(id: id, body: UndoneRequest(scheduledDate: "2026-04-21"))
        )
        XCTAssertFalse(undone.isDone)
        XCTAssertNil(undone.completedAt)
        XCTAssertEqual(undone.scheduledDate, "2026-04-21")
    }

    /// Move across lanes.
    func test_moveAcrossLanes() async throws {
        let client = makeClient()
        let id = UUID()
        let created: APITodoItem = try await client.request(
            .createItem(body: createRequest(id: id, priority: 1))
        )
        XCTAssertEqual(created.priority, 1)

        let moved: APITodoItem = try await client.request(
            .moveItem(id: id, body: MoveRequest(toPriority: 2, atIndex: 0))
        )
        XCTAssertEqual(moved.priority, 2)
    }

    /// Reschedule to a new date.
    func test_reschedule() async throws {
        let client = makeClient()
        let id = UUID()
        _ = try await client.request(.createItem(body: createRequest(id: id, date: "2026-04-22"))) as APITodoItem

        let rescheduled: APITodoItem = try await client.request(
            .rescheduleItem(id: id, body: RescheduleRequest(toDate: "2026-04-30", resetCount: true))
        )
        XCTAssertEqual(rescheduled.scheduledDate, "2026-04-30")
    }

    /// Reorder updates sort_order atomically for all ids in a lane.
    func test_reorderLane() async throws {
        let client = makeClient()
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            _ = try await client.request(.createItem(
                body: CreateItemRequest(
                    id: id,
                    title: "r-\(index)",
                    priority: 2,
                    scheduledDate: "2026-04-22",
                    reminderDate: nil,
                    sortOrder: index,
                    sourceRepeatingId: nil,
                    sourceRepeatingRuleName: nil
                )
            )) as APITodoItem
        }
        // Reorder in reverse.
        let reversed = Array(ids.reversed())
        _ = try await client.request(.reorderItems(
            body: ReorderRequest(date: "2026-04-22", priority: 2, ids: reversed)
        )) as ItemsResponse

        // Read back and verify sort order matches the POSTed order.
        let list: ItemsResponse = try await client.request(.getItems(date: "2026-04-22", priority: 2))
        XCTAssertEqual(list.items.map(\.id), reversed)
    }

    /// DELETE is idempotent: deleting twice returns 204 both times and
    /// the row stays gone.
    func test_deleteIsIdempotent() async throws {
        let client = makeClient()
        let id = UUID()
        _ = try await client.request(.createItem(body: createRequest(id: id))) as APITodoItem
        try await client.requestNoContent(.deleteItem(id: id))
        try await client.requestNoContent(.deleteItem(id: id))
        // GET the item via /sync — shouldn't appear in upserted.
        let sync: SyncResponse = try await client.request(.sync(since: "1970-01-01T00:00:00Z"))
        XCTAssertFalse(sync.items.upserted.contains(where: { $0.id == id }))
    }

    /// /sync with a past timestamp returns deletions plus upserts since then.
    func test_sync_reportsDeletedIds() async throws {
        let client = makeClient()
        let id = UUID()
        _ = try await client.request(.createItem(body: createRequest(id: id))) as APITodoItem
        // Snapshot "now" from the server by doing a sync and reading server_time.
        let before: SyncResponse = try await client.request(.sync(since: "1970-01-01T00:00:00Z"))
        let since = before.serverTime
        try await Task.sleep(for: .milliseconds(1100))
        try await client.requestNoContent(.deleteItem(id: id))

        let after: SyncResponse = try await client.request(.sync(since: since))
        XCTAssertTrue(
            after.items.deleted.contains(id),
            "deleted id not reported in /sync.deleted after delete"
        )
    }

    /// A second auth with wrong password must be rejected.
    func test_auth_wrongPasswordReturns401() async throws {
        do {
            _ = try await APIClient.authenticate(
                serverURL: serverURL,
                username: ProcessInfo.processInfo.environment["YATA_LIVE_USERNAME"] ?? "?",
                password: "__definitely_wrong_\(UUID().uuidString)"
            )
            XCTFail("expected 401, got a token")
        } catch APIError.unauthorized {
            // success
        } catch {
            XCTFail("expected APIError.unauthorized, got \(error)")
        }
    }
}
