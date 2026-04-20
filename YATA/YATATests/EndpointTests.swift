import XCTest
@testable import YATA

final class EndpointTests: XCTestCase {

    // MARK: - Health & Auth

    func testHealth() {
        let endpoint = Endpoint.health
        XCTAssertEqual(endpoint.path, "/health")
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertNil(endpoint.queryItems)
    }

    func testAuthToken() throws {
        let endpoint = Endpoint.authToken(username: "alice", password: "hunter2")
        XCTAssertEqual(endpoint.path, "/auth/token")
        XCTAssertEqual(endpoint.method, "POST")
        XCTAssertNil(endpoint.queryItems)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try endpoint.bodyData(encoder: encoder)
        XCTAssertNotNil(data)
        let json = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
        XCTAssertEqual(json["username"] as? String, "alice")
        XCTAssertEqual(json["password"] as? String, "hunter2")
    }

    // MARK: - Todo Items

    func testGetItems() {
        let endpoint = Endpoint.getItems(date: "2026-04-05", priority: 2)
        XCTAssertEqual(endpoint.path, "/items")
        XCTAssertEqual(endpoint.method, "GET")
        let items = endpoint.queryItems!
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], URLQueryItem(name: "date", value: "2026-04-05"))
        XCTAssertEqual(items[1], URLQueryItem(name: "priority", value: "2"))
    }

    func testGetItemsNoPriority() {
        let endpoint = Endpoint.getItems(date: "2026-04-05", priority: nil)
        let items = endpoint.queryItems!
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0], URLQueryItem(name: "date", value: "2026-04-05"))
    }

    func testGetDoneItems() {
        let endpoint = Endpoint.getDoneItems(limit: 25, offset: 10)
        XCTAssertEqual(endpoint.path, "/items/done")
        XCTAssertEqual(endpoint.method, "GET")
        let items = endpoint.queryItems!
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], URLQueryItem(name: "limit", value: "25"))
        XCTAssertEqual(items[1], URLQueryItem(name: "offset", value: "10"))
    }

    func testGetDoneItemsNoParams() {
        let endpoint = Endpoint.getDoneItems(limit: nil, offset: nil)
        XCTAssertNil(endpoint.queryItems)
    }

    func testCreateItem() throws {
        let body = CreateItemRequest(
            id: UUID(),
            title: "Test",
            priority: 2,
            scheduledDate: "2026-04-05",
            reminderDate: nil,
            sortOrder: 0,
            sourceRepeatingId: nil,
            sourceRepeatingRuleName: nil
        )
        let endpoint = Endpoint.createItem(body: body)
        XCTAssertEqual(endpoint.path, "/items")
        XCTAssertEqual(endpoint.method, "POST")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try endpoint.bodyData(encoder: encoder)
        XCTAssertNotNil(data)
    }

    func testUpdateItem() {
        let id = UUID()
        let body = UpdateItemRequest(
            title: "Updated", priority: 1, isDone: false, sortOrder: 0,
            reminderDate: nil, scheduledDate: "2026-04-05", rescheduleCount: 0, updatedAt: nil
        )
        let endpoint = Endpoint.updateItem(id: id, body: body)
        XCTAssertEqual(endpoint.path, "/items/\(id)")
        XCTAssertEqual(endpoint.method, "PUT")
    }

    func testDeleteItem() throws {
        let id = UUID()
        let endpoint = Endpoint.deleteItem(id: id)
        XCTAssertEqual(endpoint.path, "/items/\(id)")
        XCTAssertEqual(endpoint.method, "DELETE")
        XCTAssertNil(endpoint.queryItems)

        let encoder = JSONEncoder()
        let data = try endpoint.bodyData(encoder: encoder)
        XCTAssertNil(data)
    }

    // MARK: - Batch Operations

    func testReorderItems() {
        let body = ReorderRequest(date: "2026-04-05", priority: 2, ids: [UUID(), UUID()])
        let endpoint = Endpoint.reorderItems(body: body)
        XCTAssertEqual(endpoint.path, "/items/reorder")
        XCTAssertEqual(endpoint.method, "POST")
    }

    func testMoveItem() {
        let id = UUID()
        let body = MoveRequest(toPriority: 1, atIndex: 2)
        let endpoint = Endpoint.moveItem(id: id, body: body)
        XCTAssertEqual(endpoint.path, "/items/\(id)/move")
        XCTAssertEqual(endpoint.method, "POST")
    }

    func testMarkDone() throws {
        let id = UUID()
        let endpoint = Endpoint.markDone(id: id)
        XCTAssertEqual(endpoint.path, "/items/\(id)/done")
        XCTAssertEqual(endpoint.method, "POST")

        let encoder = JSONEncoder()
        let data = try endpoint.bodyData(encoder: encoder)
        XCTAssertNil(data)
    }

    func testMarkUndone() {
        let id = UUID()
        let body = UndoneRequest(scheduledDate: "2026-04-05")
        let endpoint = Endpoint.markUndone(id: id, body: body)
        XCTAssertEqual(endpoint.path, "/items/\(id)/undone")
        XCTAssertEqual(endpoint.method, "POST")
    }

    func testRescheduleItem() {
        let id = UUID()
        let body = RescheduleRequest(toDate: "2026-04-06", resetCount: false)
        let endpoint = Endpoint.rescheduleItem(id: id, body: body)
        XCTAssertEqual(endpoint.path, "/items/\(id)/reschedule")
        XCTAssertEqual(endpoint.method, "POST")
    }

    // MARK: - Server-Side Operations

    func testRollover() {
        let body = RolloverRequest(toDate: "2026-04-05")
        let endpoint = Endpoint.rollover(body: body)
        XCTAssertEqual(endpoint.path, "/operations/rollover")
        XCTAssertEqual(endpoint.method, "POST")
    }

    func testMaterialize() {
        let body = MaterializeRequest(startDate: "2026-04-05", endDate: "2026-04-11")
        let endpoint = Endpoint.materialize(body: body)
        XCTAssertEqual(endpoint.path, "/operations/materialize")
        XCTAssertEqual(endpoint.method, "POST")
    }

    // MARK: - Analytics

    func testStatsCounts() {
        let endpoint = Endpoint.statsCounts(dates: "2026-04-05,2026-04-06")
        XCTAssertEqual(endpoint.path, "/stats/counts")
        XCTAssertEqual(endpoint.method, "GET")
        let items = endpoint.queryItems!
        XCTAssertEqual(items[0], URLQueryItem(name: "dates", value: "2026-04-05,2026-04-06"))
    }

    func testStatsDoneCount() {
        let endpoint = Endpoint.statsDoneCount(date: "2026-04-05")
        XCTAssertEqual(endpoint.path, "/stats/done-count")
        XCTAssertEqual(endpoint.method, "GET")
        let items = endpoint.queryItems!
        XCTAssertEqual(items[0], URLQueryItem(name: "date", value: "2026-04-05"))
    }

    // MARK: - Repeating Items

    func testGetRepeating() {
        let endpoint = Endpoint.getRepeating
        XCTAssertEqual(endpoint.path, "/repeating")
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertNil(endpoint.queryItems)
    }

    func testCreateRepeating() {
        let body = CreateRepeatingRequest(
            id: UUID(), title: "Standup", frequency: 0,
            scheduledTime: "09:00:00", scheduledDayOfWeek: nil,
            scheduledDayOfMonth: nil, scheduledMonth: nil,
            sortOrder: 0, defaultUrgency: 2
        )
        let endpoint = Endpoint.createRepeating(body: body)
        XCTAssertEqual(endpoint.path, "/repeating")
        XCTAssertEqual(endpoint.method, "POST")
    }

    func testUpdateRepeating() {
        let id = UUID()
        let body = UpdateRepeatingRequest(
            title: "Standup", frequency: 0,
            scheduledTime: "09:00:00", scheduledDayOfWeek: nil,
            scheduledDayOfMonth: nil, scheduledMonth: nil,
            sortOrder: 0, defaultUrgency: 2, updatedAt: nil
        )
        let endpoint = Endpoint.updateRepeating(id: id, body: body)
        XCTAssertEqual(endpoint.path, "/repeating/\(id)")
        XCTAssertEqual(endpoint.method, "PUT")
    }

    func testDeleteRepeating() {
        let id = UUID()
        let endpoint = Endpoint.deleteRepeating(id: id)
        XCTAssertEqual(endpoint.path, "/repeating/\(id)")
        XCTAssertEqual(endpoint.method, "DELETE")
    }

    // MARK: - Sync

    func testSync() {
        let endpoint = Endpoint.sync(since: "2026-04-05T14:30:00Z")
        XCTAssertEqual(endpoint.path, "/sync")
        XCTAssertEqual(endpoint.method, "GET")
        let items = endpoint.queryItems!
        XCTAssertEqual(items[0], URLQueryItem(name: "since", value: "2026-04-05T14:30:00Z"))
    }
}
