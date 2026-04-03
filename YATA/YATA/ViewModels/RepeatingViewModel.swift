import Foundation
import SwiftUI

@MainActor
@Observable
final class RepeatingViewModel {
    private let repository: any RepeatingRepository

    var items: [RepeatingItem] = []
    var isLoading = false
    var editingItem: RepeatingItem?
    var isAdding = false
    var errorMessage: String?
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    init(repository: any RepeatingRepository) {
        self.repository = repository
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await repository.fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItem(
        title: String,
        frequency: RepeatFrequency,
        scheduledTime: Date,
        dayOfWeek: Int? = nil,
        dayOfMonth: Int? = nil,
        month: Int? = nil,
        defaultUrgency: Priority = .high
    ) async {
        let item = RepeatingItem(
            title: title,
            frequency: frequency,
            scheduledTime: scheduledTime,
            scheduledDayOfWeek: dayOfWeek,
            scheduledDayOfMonth: dayOfMonth,
            scheduledMonth: month,
            sortOrder: items.count,
            defaultUrgency: defaultUrgency
        )
        do {
            try await repository.add(item)
            items.append(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateItem(_ item: RepeatingItem) async {
        do {
            try await repository.update(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: RepeatingItem) async {
        do {
            try await repository.delete(item)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
