import Foundation
import SwiftData

@MainActor
protocol TodoRepository {
    func fetchItems(for date: Date, priority: Priority) async throws -> [TodoItem]
    func fetchDoneItems(limit: Int) async throws -> [TodoItem]
    func add(_ item: TodoItem) async throws
    func update(_ item: TodoItem) async throws
    func delete(_ item: TodoItem) async throws
    func reorder(ids: [UUID], in priority: Priority) async throws
    func move(_ item: TodoItem, to priority: Priority) async throws
    func rolloverOverdueItems(to date: Date) async throws
    func materializeRepeatingItems(for dateRange: ClosedRange<Date>) async throws
    func reschedule(_ item: TodoItem, to date: Date, resetCount: Bool) async throws
    func deleteUndoneOccurrences(for repeatingID: UUID) async throws
    func fetchTaskCountsByPriority(for dates: [Date]) async throws -> [Date: [Priority: Int]]
    func countDoneItems(for date: Date) async throws -> Int
    func fetchRepeatingItem(by id: UUID) async throws -> RepeatingItem?
    /// Fetch a single TodoItem by its stable id. Used by paths that
    /// know the id but don't have a reference to the live model
    /// object — notably notification-action handlers (`Mark Done`,
    /// `Snooze 30`, `Tomorrow`) which receive only the id from the
    /// `userInfo` dictionary. Returns nil if the row has been
    /// deleted since the notification was scheduled.
    func fetchTodoItem(by id: UUID) async throws -> TodoItem?
}
