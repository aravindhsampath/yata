import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID = UUID()
    var title: String = ""
    var priorityRawValue: Int = 1
    var isDone: Bool = false
    var sortOrder: Int = 0
    var reminderDate: Date?
    var createdAt: Date = Date.now
    var completedAt: Date?

    var priority: Priority {
        get { Priority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }

    init(
        title: String,
        priority: Priority = .medium,
        reminderDate: Date? = nil,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.title = title
        self.priorityRawValue = priority.rawValue
        self.isDone = false
        self.sortOrder = sortOrder
        self.reminderDate = reminderDate
        self.createdAt = .now
        self.completedAt = nil
    }
}
