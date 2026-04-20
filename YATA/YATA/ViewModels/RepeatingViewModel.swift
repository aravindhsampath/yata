import Foundation
import SwiftUI

@MainActor
@Observable
final class RepeatingViewModel {
    private let repository: any RepeatingRepository
    private let todoRepository: (any TodoRepository)?
    /// Pull-only sync coordinator. Non-nil in API mode — used by
    /// `handleWriteError` to resync server truth after a failed write.
    /// Nil in Local mode, in which case the helper just surfaces the
    /// error message (unchanged pre-refactor behavior).
    private let syncEngine: SyncEngine?

    var items: [RepeatingItem] = []
    var isLoading = false
    var editingItem: RepeatingItem?
    var isAdding = false
    var errorMessage: String?
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    init(
        repository: any RepeatingRepository,
        todoRepository: (any TodoRepository)? = nil,
        syncEngine: SyncEngine? = nil
    ) {
        self.repository = repository
        self.todoRepository = todoRepository
        self.syncEngine = syncEngine
    }

    /// Standard catch-block helper. Surfaces the error to the UI and — in
    /// API mode — fires a background pull so the local cache matches
    /// server truth after a failed write. On 401 posts `.yataSessionExpired`
    /// instead (pulling would also 401); ContentView handles the re-login
    /// prompt.
    private func handleWriteError(_ error: Error) {
        if case APIError.unauthorized = error {
            errorMessage = "Session expired. Please sign in again."
            NotificationCenter.default.post(name: .yataSessionExpired, object: nil)
            return
        }
        errorMessage = error.localizedDescription
        guard let engine = syncEngine else { return }
        Task {
            try? await engine.fullSync()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        }
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await repository.fetchItems()
        } catch {
            handleWriteError(error)
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
            handleWriteError(error)
        }
    }

    func updateItem(_ item: RepeatingItem) async {
        do {
            try await repository.update(item)
        } catch {
            handleWriteError(error)
        }
    }

    func deleteItem(_ item: RepeatingItem) async {
        do {
            try await todoRepository?.deleteUndoneOccurrences(for: item.id)
            try await repository.delete(item)
            items.removeAll { $0.id == item.id }
        } catch {
            handleWriteError(error)
        }
    }
}
