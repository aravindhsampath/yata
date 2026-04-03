import Foundation
import SwiftData

@Model
final class TodoItem {
    #Index<TodoItem>([\.isDone, \.scheduledDate, \.priorityRawValue, \.sortOrder])

    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var priorityRawValue: Int = 1
    var isDone: Bool = false
    var sortOrder: Int = 0
    var reminderDate: Date?
    var createdAt: Date = Date.now
    var completedAt: Date?
    var scheduledDate: Date = TodoItem.startOfToday
    var sourceRepeatingID: UUID?
    var rescheduleCount: Int = 0

    var priority: Priority {
        get { Priority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }

    /// Whether this item was spawned from a repeating rule
    var isRepeatingOccurrence: Bool { sourceRepeatingID != nil }

    init(
        title: String,
        priority: Priority = .medium,
        reminderDate: Date? = nil,
        sortOrder: Int = 0,
        scheduledDate: Date? = nil,
        sourceRepeatingID: UUID? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.priorityRawValue = priority.rawValue
        self.isDone = false
        self.sortOrder = sortOrder
        self.reminderDate = reminderDate
        self.createdAt = .now
        self.completedAt = nil
        self.scheduledDate = scheduledDate ?? TodoItem.startOfToday
        self.sourceRepeatingID = sourceRepeatingID
        self.rescheduleCount = 0
    }

    /// Start of today with time components stripped — used for date-only comparisons
    static var startOfToday: Date {
        Calendar.current.startOfDay(for: .now)
    }
}
