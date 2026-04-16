import Foundation

struct AuthRequest: Encodable {
    let username: String
    let password: String
}

struct CreateItemRequest: Encodable {
    let id: UUID
    let title: String
    let priority: Int
    let scheduledDate: String
    let reminderDate: String?
    let sortOrder: Int
    let sourceRepeatingId: UUID?
    let sourceRepeatingRuleName: String?
}

struct UpdateItemRequest: Encodable {
    let title: String
    let priority: Int
    let isDone: Bool
    let sortOrder: Int
    let reminderDate: String?
    let scheduledDate: String
    let rescheduleCount: Int
    let updatedAt: String?
}

struct ReorderRequest: Encodable {
    let date: String
    let priority: Int
    let ids: [UUID]
}

struct MoveRequest: Encodable {
    let toPriority: Int
    let atIndex: Int
}

struct UndoneRequest: Encodable {
    let scheduledDate: String
}

struct RescheduleRequest: Encodable {
    let toDate: String
    let resetCount: Bool
}

struct RolloverRequest: Encodable {
    let toDate: String
}

struct MaterializeRequest: Encodable {
    let startDate: String
    let endDate: String
}

struct CreateRepeatingRequest: Encodable {
    let id: UUID
    let title: String
    let frequency: Int
    let scheduledTime: String
    let scheduledDayOfWeek: Int?
    let scheduledDayOfMonth: Int?
    let scheduledMonth: Int?
    let sortOrder: Int
    let defaultUrgency: Int
}

struct UpdateRepeatingRequest: Encodable {
    let title: String
    let frequency: Int
    let scheduledTime: String
    let scheduledDayOfWeek: Int?
    let scheduledDayOfMonth: Int?
    let scheduledMonth: Int?
    let sortOrder: Int
    let defaultUrgency: Int
    let updatedAt: String?
}
