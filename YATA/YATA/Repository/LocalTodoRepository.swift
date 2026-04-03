import Foundation
import SwiftData

@ModelActor
actor LocalTodoRepository: TodoRepository {

    func fetchItems(priority: Priority) throws -> [TodoItem] {
        let rawValue = priority.rawValue
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.priorityRawValue == rawValue
        }
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor)
    }

    func fetchDoneItems() throws -> [TodoItem] {
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == true
        }
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func add(_ item: TodoItem) throws {
        modelContext.insert(item)
        try modelContext.save()
    }

    func update(_ item: TodoItem) throws {
        try modelContext.save()
    }

    func delete(_ item: TodoItem) throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    func reorder(ids: [UUID], in priority: Priority) throws {
        let rawValue = priority.rawValue
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.priorityRawValue == rawValue
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let items = try modelContext.fetch(descriptor)

        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            lookup[id]?.sortOrder = index
        }
        try modelContext.save()
    }

    func move(_ item: TodoItem, to priority: Priority) throws {
        item.priority = priority
        // Place at end of target priority
        let rawValue = priority.rawValue
        let predicate = #Predicate<TodoItem> { existing in
            existing.isDone == false && existing.priorityRawValue == rawValue
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let count = try modelContext.fetchCount(descriptor)
        item.sortOrder = count
        try modelContext.save()
    }
}
