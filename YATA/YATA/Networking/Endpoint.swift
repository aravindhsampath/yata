import Foundation

enum Endpoint {
    // Health & Auth
    case health
    case authToken(secret: String)

    // Todo Items
    case getItems(date: String, priority: Int?)
    case getDoneItems(limit: Int?, offset: Int?)
    case createItem(body: CreateItemRequest)
    case updateItem(id: UUID, body: UpdateItemRequest)
    case deleteItem(id: UUID)

    // Batch Operations
    case reorderItems(body: ReorderRequest)
    case moveItem(id: UUID, body: MoveRequest)
    case markDone(id: UUID)
    case markUndone(id: UUID, body: UndoneRequest)
    case rescheduleItem(id: UUID, body: RescheduleRequest)

    // Server-Side Operations
    case rollover(body: RolloverRequest)
    case materialize(body: MaterializeRequest)

    // Analytics
    case statsCounts(dates: String)
    case statsDoneCount(date: String)

    // Repeating Items
    case getRepeating
    case createRepeating(body: CreateRepeatingRequest)
    case updateRepeating(id: UUID, body: UpdateRepeatingRequest)
    case deleteRepeating(id: UUID)

    // Sync
    case sync(since: String)

    var path: String {
        switch self {
        case .health: "/health"
        case .authToken: "/auth/token"
        case .getItems: "/items"
        case .getDoneItems: "/items/done"
        case .createItem: "/items"
        case .updateItem(let id, _): "/items/\(id)"
        case .deleteItem(let id): "/items/\(id)"
        case .reorderItems: "/items/reorder"
        case .moveItem(let id, _): "/items/\(id)/move"
        case .markDone(let id): "/items/\(id)/done"
        case .markUndone(let id, _): "/items/\(id)/undone"
        case .rescheduleItem(let id, _): "/items/\(id)/reschedule"
        case .rollover: "/operations/rollover"
        case .materialize: "/operations/materialize"
        case .statsCounts: "/stats/counts"
        case .statsDoneCount: "/stats/done-count"
        case .getRepeating: "/repeating"
        case .createRepeating: "/repeating"
        case .updateRepeating(let id, _): "/repeating/\(id)"
        case .deleteRepeating(let id): "/repeating/\(id)"
        case .sync: "/sync"
        }
    }

    var method: String {
        switch self {
        case .health, .getItems, .getDoneItems, .statsCounts, .statsDoneCount,
             .getRepeating, .sync:
            "GET"
        case .authToken, .createItem, .reorderItems, .moveItem, .markDone,
             .markUndone, .rescheduleItem, .rollover, .materialize, .createRepeating:
            "POST"
        case .updateItem, .updateRepeating:
            "PUT"
        case .deleteItem, .deleteRepeating:
            "DELETE"
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .getItems(let date, let priority):
            var items = [URLQueryItem(name: "date", value: date)]
            if let priority {
                items.append(URLQueryItem(name: "priority", value: "\(priority)"))
            }
            return items

        case .getDoneItems(let limit, let offset):
            var items: [URLQueryItem] = []
            if let limit { items.append(URLQueryItem(name: "limit", value: "\(limit)")) }
            if let offset { items.append(URLQueryItem(name: "offset", value: "\(offset)")) }
            return items.isEmpty ? nil : items

        case .statsCounts(let dates):
            return [URLQueryItem(name: "dates", value: dates)]

        case .statsDoneCount(let date):
            return [URLQueryItem(name: "date", value: date)]

        case .sync(let since):
            return [URLQueryItem(name: "since", value: since)]

        default:
            return nil
        }
    }

    func bodyData(encoder: JSONEncoder) throws -> Data? {
        switch self {
        case .authToken(let secret):
            try encoder.encode(AuthRequest(secret: secret))
        case .createItem(let body):
            try encoder.encode(body)
        case .updateItem(_, let body):
            try encoder.encode(body)
        case .reorderItems(let body):
            try encoder.encode(body)
        case .moveItem(_, let body):
            try encoder.encode(body)
        case .markUndone(_, let body):
            try encoder.encode(body)
        case .rescheduleItem(_, let body):
            try encoder.encode(body)
        case .rollover(let body):
            try encoder.encode(body)
        case .materialize(let body):
            try encoder.encode(body)
        case .createRepeating(let body):
            try encoder.encode(body)
        case .updateRepeating(_, let body):
            try encoder.encode(body)
        default:
            nil
        }
    }
}
