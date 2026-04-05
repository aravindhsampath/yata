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
    let serverVersion: AnyCodable?
}

/// Minimal type-erased Codable wrapper for the optional `server_version` field in error responses.
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String: try container.encode(string)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: Any]:
            let wrapped = dict.mapValues { AnyCodable(value: $0) }
            try container.encode(wrapped)
        case let array as [Any]:
            let wrapped = array.map { AnyCodable(value: $0) }
            try container.encode(wrapped)
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }

    init(value: Any) {
        self.value = value
    }
}
