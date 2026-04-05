import XCTest
@testable import YATA

final class DTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = .sortedKeys
        return e
    }()

    // MARK: - APITodoItem

    func testDecodeTodoItem() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Call roof guy",
          "priority": 2,
          "is_done": false,
          "sort_order": 3,
          "reminder_date": "2026-04-05T14:00:00Z",
          "created_at": "2026-04-05T08:00:00Z",
          "completed_at": null,
          "scheduled_date": "2026-04-05",
          "source_repeating_id": null,
          "source_repeating_rule_name": null,
          "reschedule_count": 0,
          "updated_at": "2026-04-05T08:00:00Z"
        }
        """.data(using: .utf8)!

        let item = try decoder.decode(APITodoItem.self, from: json)
        XCTAssertEqual(item.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(item.title, "Call roof guy")
        XCTAssertEqual(item.priority, 2)
        XCTAssertFalse(item.isDone)
        XCTAssertEqual(item.sortOrder, 3)
        XCTAssertEqual(item.reminderDate, "2026-04-05T14:00:00Z")
        XCTAssertEqual(item.createdAt, "2026-04-05T08:00:00Z")
        XCTAssertNil(item.completedAt)
        XCTAssertEqual(item.scheduledDate, "2026-04-05")
        XCTAssertNil(item.sourceRepeatingId)
        XCTAssertNil(item.sourceRepeatingRuleName)
        XCTAssertEqual(item.rescheduleCount, 0)
        XCTAssertEqual(item.updatedAt, "2026-04-05T08:00:00Z")
    }

    func testTodoItemRoundTrip() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Test item",
          "priority": 1,
          "is_done": true,
          "sort_order": 0,
          "reminder_date": null,
          "created_at": "2026-04-05T08:00:00Z",
          "completed_at": "2026-04-05T10:00:00Z",
          "scheduled_date": "2026-04-05",
          "source_repeating_id": "660e8400-e29b-41d4-a716-446655440000",
          "source_repeating_rule_name": "Daily standup",
          "reschedule_count": 2,
          "updated_at": "2026-04-05T10:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(APITodoItem.self, from: json)
        let reEncoded = try encoder.encode(decoded)
        let reDecoded = try decoder.decode(APITodoItem.self, from: reEncoded)
        XCTAssertEqual(decoded.id, reDecoded.id)
        XCTAssertEqual(decoded.title, reDecoded.title)
        XCTAssertEqual(decoded.priority, reDecoded.priority)
        XCTAssertEqual(decoded.isDone, reDecoded.isDone)
        XCTAssertEqual(decoded.scheduledDate, reDecoded.scheduledDate)
        XCTAssertEqual(decoded.updatedAt, reDecoded.updatedAt)
    }

    func testTodoItemConversionToModel() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Test",
          "priority": 2,
          "is_done": false,
          "sort_order": 1,
          "reminder_date": null,
          "created_at": "2026-04-05T08:00:00Z",
          "completed_at": null,
          "scheduled_date": "2026-04-05",
          "source_repeating_id": null,
          "source_repeating_rule_name": null,
          "reschedule_count": 0,
          "updated_at": "2026-04-05T08:00:00Z"
        }
        """.data(using: .utf8)!

        let dto = try decoder.decode(APITodoItem.self, from: json)
        let model = dto.toTodoItem()
        XCTAssertEqual(model.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(model.title, "Test")
        XCTAssertEqual(model.priority, .high)
        XCTAssertFalse(model.isDone)
        XCTAssertEqual(model.sortOrder, 1)
        XCTAssertNotNil(model.updatedAt)
    }

    func testTodoItemConversionFromModel() {
        let model = TodoItem(title: "From model", priority: .low, sortOrder: 5)
        let dto = APITodoItem(from: model)
        XCTAssertEqual(dto.title, "From model")
        XCTAssertEqual(dto.priority, 0)
        XCTAssertEqual(dto.sortOrder, 5)
        XCTAssertFalse(dto.isDone)
        XCTAssertNil(dto.updatedAt) // local-only items have nil updatedAt
    }

    // MARK: - APIRepeatingItem

    func testDecodeRepeatingItem() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Daily standup",
          "frequency": 0,
          "scheduled_time": "09:00:00",
          "scheduled_day_of_week": null,
          "scheduled_day_of_month": null,
          "scheduled_month": null,
          "sort_order": 0,
          "default_urgency": 2,
          "updated_at": "2026-04-05T08:00:00Z"
        }
        """.data(using: .utf8)!

        let item = try decoder.decode(APIRepeatingItem.self, from: json)
        XCTAssertEqual(item.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(item.title, "Daily standup")
        XCTAssertEqual(item.frequency, 0)
        XCTAssertEqual(item.scheduledTime, "09:00:00")
        XCTAssertNil(item.scheduledDayOfWeek)
        XCTAssertEqual(item.sortOrder, 0)
        XCTAssertEqual(item.defaultUrgency, 2)
        XCTAssertEqual(item.updatedAt, "2026-04-05T08:00:00Z")
    }

    func testRepeatingItemRoundTrip() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Weekly review",
          "frequency": 2,
          "scheduled_time": "14:30:00",
          "scheduled_day_of_week": 2,
          "scheduled_day_of_month": null,
          "scheduled_month": null,
          "sort_order": 1,
          "default_urgency": 1,
          "updated_at": "2026-04-05T08:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(APIRepeatingItem.self, from: json)
        let reEncoded = try encoder.encode(decoded)
        let reDecoded = try decoder.decode(APIRepeatingItem.self, from: reEncoded)
        XCTAssertEqual(decoded.id, reDecoded.id)
        XCTAssertEqual(decoded.title, reDecoded.title)
        XCTAssertEqual(decoded.frequency, reDecoded.frequency)
        XCTAssertEqual(decoded.scheduledTime, reDecoded.scheduledTime)
        XCTAssertEqual(decoded.scheduledDayOfWeek, reDecoded.scheduledDayOfWeek)
    }

    func testRepeatingItemConversionToModel() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "Daily standup",
          "frequency": 0,
          "scheduled_time": "09:00:00",
          "scheduled_day_of_week": null,
          "scheduled_day_of_month": null,
          "scheduled_month": null,
          "sort_order": 0,
          "default_urgency": 2,
          "updated_at": "2026-04-05T08:00:00Z"
        }
        """.data(using: .utf8)!

        let dto = try decoder.decode(APIRepeatingItem.self, from: json)
        let model = dto.toRepeatingItem()
        XCTAssertEqual(model.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(model.title, "Daily standup")
        XCTAssertEqual(model.frequency, .daily)
        XCTAssertEqual(model.defaultUrgency, .high)
        XCTAssertNotNil(model.updatedAt)
    }

    // MARK: - Response Bodies

    func testDecodeHealthResponse() throws {
        let json = """
        { "status": "ok", "version": "1.0.0" }
        """.data(using: .utf8)!
        let resp = try decoder.decode(HealthResponse.self, from: json)
        XCTAssertEqual(resp.status, "ok")
        XCTAssertEqual(resp.version, "1.0.0")
    }

    func testDecodeAuthTokenResponse() throws {
        let json = """
        { "token": "eyJhbGciOi...", "expires_at": "2026-05-05T00:00:00Z" }
        """.data(using: .utf8)!
        let resp = try decoder.decode(AuthTokenResponse.self, from: json)
        XCTAssertEqual(resp.token, "eyJhbGciOi...")
        XCTAssertEqual(resp.expiresAt, "2026-05-05T00:00:00Z")
    }

    func testDecodeItemsResponse() throws {
        let json = """
        {
          "items": [{
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "title": "Test",
            "priority": 0,
            "is_done": false,
            "sort_order": 0,
            "reminder_date": null,
            "created_at": "2026-04-05T08:00:00Z",
            "completed_at": null,
            "scheduled_date": "2026-04-05",
            "source_repeating_id": null,
            "source_repeating_rule_name": null,
            "reschedule_count": 0,
            "updated_at": "2026-04-05T08:00:00Z"
          }]
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(ItemsResponse.self, from: json)
        XCTAssertEqual(resp.items.count, 1)
    }

    func testDecodeDoneItemsResponse() throws {
        let json = """
        { "items": [], "total": 42 }
        """.data(using: .utf8)!
        let resp = try decoder.decode(DoneItemsResponse.self, from: json)
        XCTAssertEqual(resp.total, 42)
        XCTAssertTrue(resp.items.isEmpty)
    }

    func testDecodeStatsCountsResponse() throws {
        let json = """
        {
          "counts": {
            "2026-04-05": { "0": 2, "1": 3, "2": 1 },
            "2026-04-06": { "0": 0, "1": 1, "2": 4 }
          }
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(StatsCountsResponse.self, from: json)
        XCTAssertEqual(resp.counts["2026-04-05"]?["2"], 1)
        XCTAssertEqual(resp.counts["2026-04-06"]?["1"], 1)
    }

    func testDecodeStatsDoneCountResponse() throws {
        let json = """
        { "count": 7 }
        """.data(using: .utf8)!
        let resp = try decoder.decode(StatsDoneCountResponse.self, from: json)
        XCTAssertEqual(resp.count, 7)
    }

    func testDecodeRolloverResponse() throws {
        let json = """
        { "rolled_over_count": 5 }
        """.data(using: .utf8)!
        let resp = try decoder.decode(RolloverResponse.self, from: json)
        XCTAssertEqual(resp.rolledOverCount, 5)
    }

    func testDecodeMaterializeResponse() throws {
        let json = """
        { "created_count": 12 }
        """.data(using: .utf8)!
        let resp = try decoder.decode(MaterializeResponse.self, from: json)
        XCTAssertEqual(resp.createdCount, 12)
    }

    func testDecodeSyncResponse() throws {
        let json = """
        {
          "items": {
            "upserted": [{
              "id": "550e8400-e29b-41d4-a716-446655440000",
              "title": "Synced item",
              "priority": 1,
              "is_done": false,
              "sort_order": 0,
              "reminder_date": null,
              "created_at": "2026-04-05T08:00:00Z",
              "completed_at": null,
              "scheduled_date": "2026-04-05",
              "source_repeating_id": null,
              "source_repeating_rule_name": null,
              "reschedule_count": 0,
              "updated_at": "2026-04-05T14:30:00Z"
            }],
            "deleted": ["660e8400-e29b-41d4-a716-446655440000"]
          },
          "repeating": {
            "upserted": [],
            "deleted": []
          },
          "server_time": "2026-04-05T14:30:00Z"
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(SyncResponse.self, from: json)
        XCTAssertEqual(resp.items.upserted.count, 1)
        XCTAssertEqual(resp.items.deleted.count, 1)
        XCTAssertTrue(resp.repeating.upserted.isEmpty)
        XCTAssertEqual(resp.serverTime, "2026-04-05T14:30:00Z")
    }

    func testDecodeErrorResponse() throws {
        let json = """
        {
          "error": {
            "code": "conflict",
            "message": "Item was modified on server"
          }
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(ErrorResponse.self, from: json)
        XCTAssertEqual(resp.error.code, "conflict")
        XCTAssertEqual(resp.error.message, "Item was modified on server")
    }

    // MARK: - Request Bodies Encoding

    func testEncodeCreateItemRequest() throws {
        let id = UUID()
        let body = CreateItemRequest(
            id: id, title: "New task", priority: 2,
            scheduledDate: "2026-04-05", reminderDate: "2026-04-05T14:00:00Z",
            sortOrder: 3, sourceRepeatingId: nil, sourceRepeatingRuleName: nil
        )
        let data = try encoder.encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["title"] as? String, "New task")
        XCTAssertEqual(json["priority"] as? Int, 2)
        XCTAssertEqual(json["scheduled_date"] as? String, "2026-04-05")
        XCTAssertEqual(json["reminder_date"] as? String, "2026-04-05T14:00:00Z")
        XCTAssertEqual(json["sort_order"] as? Int, 3)
    }

    func testEncodeReorderRequest() throws {
        let ids = [UUID(), UUID(), UUID()]
        let body = ReorderRequest(date: "2026-04-05", priority: 2, ids: ids)
        let data = try encoder.encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["date"] as? String, "2026-04-05")
        XCTAssertEqual(json["priority"] as? Int, 2)
        XCTAssertEqual((json["ids"] as? [String])?.count, 3)
    }

    func testEncodeMoveRequest() throws {
        let body = MoveRequest(toPriority: 1, atIndex: 2)
        let data = try encoder.encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["to_priority"] as? Int, 1)
        XCTAssertEqual(json["at_index"] as? Int, 2)
    }

    func testEncodeRescheduleRequest() throws {
        let body = RescheduleRequest(toDate: "2026-04-06", resetCount: false)
        let data = try encoder.encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["to_date"] as? String, "2026-04-06")
        XCTAssertEqual(json["reset_count"] as? Bool, false)
    }

    func testEncodeMaterializeRequest() throws {
        let body = MaterializeRequest(startDate: "2026-04-05", endDate: "2026-04-11")
        let data = try encoder.encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["start_date"] as? String, "2026-04-05")
        XCTAssertEqual(json["end_date"] as? String, "2026-04-11")
    }
}
