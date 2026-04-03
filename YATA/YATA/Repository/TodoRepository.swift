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
    func reschedule(_ item: TodoItem, to date: Date) async throws
    func deleteUndoneOccurrences(for repeatingID: UUID) async throws
}
