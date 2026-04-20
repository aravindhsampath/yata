import Foundation

struct APITodoItem: Codable {
    let id: UUID
    let title: String
    let priority: Int
    let isDone: Bool
    let sortOrder: Int
    let reminderDate: String?
    let createdAt: String
    let completedAt: String?
    let scheduledDate: String
    let sourceRepeatingId: UUID?
    let sourceRepeatingRuleName: String?
    let rescheduleCount: Int
    let updatedAt: String?

    init(from todoItem: TodoItem) {
        self.id = todoItem.id
        self.title = todoItem.title
        self.priority = todoItem.priorityRawValue
        self.isDone = todoItem.isDone
        self.sortOrder = todoItem.sortOrder
        self.reminderDate = todoItem.reminderDate.map { DateFormatters.iso8601DateTime.string(from: $0) }
        self.createdAt = DateFormatters.iso8601DateTime.string(from: todoItem.createdAt)
        self.completedAt = todoItem.completedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
        self.scheduledDate = DateFormatters.dateOnly.string(from: todoItem.scheduledDate)
        self.sourceRepeatingId = todoItem.sourceRepeatingID
        self.sourceRepeatingRuleName = todoItem.sourceRepeatingRuleName
        self.rescheduleCount = todoItem.rescheduleCount
        self.updatedAt = todoItem.updatedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
    }

    func toTodoItem() -> TodoItem {
        let item = TodoItem(
            title: title,
            priority: Priority(rawValue: priority) ?? .medium,
            reminderDate: reminderDate.flatMap { DateFormatters.parseDateTime($0) },
            sortOrder: sortOrder,
            scheduledDate: DateFormatters.dateOnly.date(from: scheduledDate),
            sourceRepeatingID: sourceRepeatingId
        )
        // Overwrite generated fields with server values
        item.id = id
        item.isDone = isDone
        item.createdAt = DateFormatters.parseDateTime(createdAt) ?? .now
        item.completedAt = completedAt.flatMap { DateFormatters.parseDateTime($0) }
        item.sourceRepeatingRuleName = sourceRepeatingRuleName
        item.rescheduleCount = rescheduleCount
        item.updatedAt = updatedAt.flatMap { DateFormatters.parseDateTime($0) }
        return item
    }
}

// MARK: - Date Formatters

enum DateFormatters {
    static let iso8601DateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `scheduled_date` strings. Uses the device's **local** time zone
    /// because a TodoItem's `scheduledDate` is set to local-midnight via
    /// `Calendar.current.startOfDay(for:)`. Formatting that instant with
    /// UTC shifts it to the previous day for anyone east of GMT near
    /// midnight, which would make newly-added tasks disappear from the
    /// "today" view on the next pull (regression observed 2026-04-20).
    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// RepeatingItem `scheduled_time` strings. Also local — users
    /// schedule repeating rules by wall-clock.
    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Parse an ISO8601 datetime string, trying with and without fractional seconds.
    static func parseDateTime(_ string: String) -> Date? {
        iso8601DateTime.date(from: string)
            ?? iso8601WithFractionalSeconds.date(from: string)
    }
}
