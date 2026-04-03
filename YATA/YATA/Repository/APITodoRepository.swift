import Foundation

/// Stub for future server-backed repository.
/// Conforms to TodoRepository so it can be swapped in via dependency injection.
struct APITodoRepository: TodoRepository {

    func fetchItems(priority: Priority) async throws -> [TodoItem] {
        []
    }

    func fetchDoneItems() async throws -> [TodoItem] {
        []
    }

    func add(_ item: TodoItem) async throws {}

    func update(_ item: TodoItem) async throws {}

    func delete(_ item: TodoItem) async throws {}

    func reorder(ids: [UUID], in priority: Priority) async throws {}

    func move(_ item: TodoItem, to priority: Priority) async throws {}
}
