import Foundation

protocol TodoRepository: Sendable {
    func fetchItems(priority: Priority) async throws -> [TodoItem]
    func fetchDoneItems() async throws -> [TodoItem]
    func add(_ item: TodoItem) async throws
    func update(_ item: TodoItem) async throws
    func delete(_ item: TodoItem) async throws
    func reorder(ids: [UUID], in priority: Priority) async throws
    func move(_ item: TodoItem, to priority: Priority) async throws
}
