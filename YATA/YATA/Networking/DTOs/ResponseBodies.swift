import Foundation

struct HealthResponse: Codable {
    let status: String
    let version: String
}

struct AuthTokenResponse: Codable {
    let token: String
    let expiresAt: String
}

struct ItemsResponse: Codable {
    let items: [APITodoItem]
}

struct DoneItemsResponse: Codable {
    let items: [APITodoItem]
    let total: Int
}

struct RepeatingItemsResponse: Codable {
    let items: [APIRepeatingItem]
}

struct StatsCountsResponse: Codable {
    let counts: [String: [String: Int]]
}

struct StatsDoneCountResponse: Codable {
    let count: Int
}

struct RolloverResponse: Codable {
    let rolledOverCount: Int
}

struct MaterializeResponse: Codable {
    let createdCount: Int
}

struct SyncResponse: Codable {
    let items: SyncDelta<APITodoItem>
    let repeating: SyncDelta<APIRepeatingItem>
    let serverTime: String
}

struct SyncDelta<T: Codable>: Codable {
    let upserted: [T]
    let deleted: [UUID]
}

struct ErrorResponse: Codable {
    let error: ErrorDetail
}

struct ErrorDetail: Codable {
    let code: String
    let message: String
    // Note: `serverVersion: AnyCodable?` and the AnyCodable type
    // it depended on were removed in P1.11 alongside the rest of
    // the optimistic-concurrency machinery. See
    // YATA/docs/conflict_resolution_redesign.md. If a stale server
    // ever does emit a `server_version` field on a 409, JSONDecoder
    // simply ignores extra keys — no crash, no compatibility
    // headache.
}
