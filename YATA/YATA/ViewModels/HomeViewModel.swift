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
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // Drag state
    var draggingItemID: UUID?
    var dropTarget: DropTarget?

    struct DropTarget: Equatable {
        let priority: Priority
        let index: Int
    }

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

    /// Called when an item is dropped at a specific index in a priority container
    func handleDrop(itemID: UUID, toPriority: Priority, atIndex: Int) async {
        // Find the item across all priorities
        let allItems = Priority.allCases.flatMap { items(for: $0) }
        guard let item = allItems.first(where: { $0.id == itemID }) else { return }

        let sourcePriority = item.priority

        if sourcePriority == toPriority {
            // Reorder within same container
            var currentItems = items(for: toPriority)
            guard let fromIndex = currentItems.firstIndex(where: { $0.id == itemID }) else { return }
            let targetIndex = atIndex > fromIndex ? atIndex - 1 : atIndex
            currentItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: targetIndex > fromIndex ? targetIndex + 1 : targetIndex)
            let ids = currentItems.map(\.id)
            setItems(currentItems, for: toPriority)
            await reorder(ids: ids, in: toPriority)
        } else {
            // Move across containers
            removeFromArray(for: sourcePriority, item: item)
            var targetItems = items(for: toPriority)
            let insertAt = min(atIndex, targetItems.count)
            item.priority = toPriority
            targetItems.insert(item, at: insertAt)
            setItems(targetItems, for: toPriority)
            // Persist
            do {
                try await repository.move(item, to: toPriority)
                let ids = targetItems.map(\.id)
                try await repository.reorder(ids: ids, in: toPriority)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        draggingItemID = nil
        dropTarget = nil
    }

    func startDrag(itemID: UUID) {
        draggingItemID = itemID
    }

    func endDrag() {
        draggingItemID = nil
        dropTarget = nil
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

    private func setItems(_ items: [TodoItem], for priority: Priority) {
        switch priority {
        case .high: highItems = items
        case .medium: mediumItems = items
        case .low: lowItems = items
        }
    }
}
