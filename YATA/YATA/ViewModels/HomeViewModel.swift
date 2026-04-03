import Foundation
import SwiftUI

@MainActor
@Observable
final class HomeViewModel {
    private let repository: any TodoRepository

    var highItems: [TodoItem] = []
    var mediumItems: [TodoItem] = []
    var lowItems: [TodoItem] = []
    var doneItems: [TodoItem] = []
    var isLoading = false
    var editingItem: TodoItem?
    var addingToPriority: Priority?
    var errorMessage: String?

    init(repository: any TodoRepository) {
        self.repository = repository
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            highItems = try await repository.fetchItems(priority: .high)
            mediumItems = try await repository.fetchItems(priority: .medium)
            lowItems = try await repository.fetchItems(priority: .low)
            doneItems = try await repository.fetchDoneItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func items(for priority: Priority) -> [TodoItem] {
        switch priority {
        case .high: highItems
        case .medium: mediumItems
        case .low: lowItems
        }
    }

    func markDone(_ item: TodoItem) async {
        item.isDone = true
        item.completedAt = .now
        do {
            try await repository.update(item)
            removeFromPriorityArray(item)
            doneItems.insert(item, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markUndone(_ item: TodoItem) async {
        item.isDone = false
        item.completedAt = nil
        do {
            try await repository.update(item)
            doneItems.removeAll { $0.id == item.id }
            appendToPriorityArray(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItem(title: String, priority: Priority, reminderDate: Date?) async {
        let count = items(for: priority).count
        let item = TodoItem(
            title: title,
            priority: priority,
            reminderDate: reminderDate,
            sortOrder: count
        )
        do {
            try await repository.add(item)
            appendToPriorityArray(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateItem(_ item: TodoItem) async {
        do {
            try await repository.update(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: TodoItem) async {
        do {
            try await repository.delete(item)
            removeFromPriorityArray(item)
            doneItems.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorder(ids: [UUID], in priority: Priority) async {
        do {
            try await repository.reorder(ids: ids, in: priority)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveItem(_ item: TodoItem, to priority: Priority) async {
        let sourcePriority = item.priority
        do {
            try await repository.move(item, to: priority)
            removeFromArray(for: sourcePriority, item: item)
            appendToArray(for: priority, item: item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Targeted array helpers

    private func removeFromPriorityArray(_ item: TodoItem) {
        removeFromArray(for: item.priority, item: item)
    }

    private func appendToPriorityArray(_ item: TodoItem) {
        appendToArray(for: item.priority, item: item)
    }

    private func removeFromArray(for priority: Priority, item: TodoItem) {
        switch priority {
        case .high: highItems.removeAll { $0.id == item.id }
        case .medium: mediumItems.removeAll { $0.id == item.id }
        case .low: lowItems.removeAll { $0.id == item.id }
        }
    }

    private func appendToArray(for priority: Priority, item: TodoItem) {
        switch priority {
        case .high: highItems.append(item)
        case .medium: mediumItems.append(item)
        case .low: lowItems.append(item)
        }
    }
}
