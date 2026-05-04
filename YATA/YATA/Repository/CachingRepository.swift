import Foundation
import SwiftData

/// Write-through repository used only in API (server-connected) mode.
///
/// Contract:
/// - Reads: always from local SwiftData cache. No network calls on the read
///   path. SyncEngine's periodic pull is what refreshes the cache.
/// - Writes: optimistic local mutation followed by an immediate API call on
///   the same call stack. On server success the local row is reconciled with
///   the server's version (specifically `updated_at`, so the next conflict
///   check uses the right timestamp). On server failure we attempt a cheap
///   rollback when the old state is snapshottable (add/move/reschedule),
///   otherwise we simply rethrow — the ViewModel is expected to trigger a
///   pull which will re-seed the cache from server truth.
/// - No batching, no mutation log, no "pending" state. A successful return
///   from any write method means the server has acknowledged it.
///
/// In Local mode this type is NOT instantiated — `RepositoryProvider` wires
/// `LocalTodoRepository` directly. Nothing here affects Local-mode behavior.
@MainActor
final class CachingRepository: TodoRepository, RepeatingRepository {
    private let local: LocalTodoRepository
    private let localRepeating: LocalRepeatingRepository
    private let apiClient: APIClient

    /// Formatter for `scheduled_date` (a calendar-day string, "yyyy-MM-dd").
    /// Uses the device's **local** time zone because `scheduledDate` in
    /// the SwiftData model is "midnight local of the day the task lands
    /// on" — set via `Calendar.current.startOfDay(for:)` in `HomeViewModel`.
    /// Formatting that instant with UTC loses the user's local day
    /// whenever the device is east of GMT and near midnight, making tasks
    /// disappear from the "today" view after a pull overwrites the field.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    init(local: LocalTodoRepository, localRepeating: LocalRepeatingRepository, apiClient: APIClient) {
        self.local = local
        self.localRepeating = localRepeating
        self.apiClient = apiClient
    }

    // MARK: - TodoRepository (read-only — no network)

    func fetchItems(for date: Date, priority: Priority) throws -> [TodoItem] {
        try local.fetchItems(for: date, priority: priority)
    }

    func fetchDoneItems(limit: Int) throws -> [TodoItem] {
        try local.fetchDoneItems(limit: limit)
    }

    func fetchTaskCountsByPriority(for dates: [Date]) throws -> [Date: [Priority: Int]] {
        try local.fetchTaskCountsByPriority(for: dates)
    }

    func countDoneItems(for date: Date) throws -> Int {
        try local.countDoneItems(for: date)
    }

    func fetchRepeatingItem(by id: UUID) throws -> RepeatingItem? {
        try local.fetchRepeatingItem(by: id)
    }

    // MARK: - TodoRepository (writes — local-then-server, rollback on failure)

    func add(_ item: TodoItem) async throws {
        try local.add(item)
        do {
            let response: APITodoItem = try await apiClient.request(
                .createItem(body: createRequest(from: item))
            )
            reconcile(server: response, into: item)
            try local.update(item)
        } catch {
            // Rollback: the item didn't exist until we just inserted it.
            try? local.delete(item)
            throw error
        }
    }

    func update(_ item: TodoItem) async throws {
        // The caller (ViewModel) has already mutated `item` in place. Commit
        // that to the store so the optimistic UI matches persistence, then
        // mirror to the server.
        try local.update(item)
        do {
            let response: APITodoItem = try await apiClient.request(
                .updateItem(id: item.id, body: updateRequest(from: item))
            )
            reconcile(server: response, into: item)
            try local.update(item)
        } catch {
            // We can't cheaply rollback (old field values weren't snapshotted
            // before the VM mutated the model). The ViewModel's catch should
            // trigger a pull so the cache resyncs to server truth.
            throw error
        }
    }

    func delete(_ item: TodoItem) async throws {
        // Delete server-first so a 5xx/network error doesn't leave the local
        // gone but the server still holding the row. The local delete only
        // happens after the server confirms.
        let id = item.id
        try await apiClient.requestNoContent(.deleteItem(id: id))
        try local.delete(item)
    }

    func reorder(ids: [UUID], in priority: Priority) async throws {
        try local.reorder(ids: ids, in: priority)
        let today = Self.dateFormatter.string(from: .now)
        let _: ItemsResponse = try await apiClient.request(
            .reorderItems(body: ReorderRequest(date: today, priority: priority.rawValue, ids: ids))
        )
        // No per-item reconciliation — the server's response covers all
        // items in the lane but our cache already reflects the new order.
        // A pull on next trigger will reconcile updated_at timestamps.
    }

    func move(_ item: TodoItem, to priority: Priority) async throws {
        let oldPriority = item.priority
        try local.move(item, to: priority)
        do {
            let response: APITodoItem = try await apiClient.request(
                .moveItem(id: item.id, body: MoveRequest(toPriority: priority.rawValue, atIndex: item.sortOrder))
            )
            reconcile(server: response, into: item)
            try local.update(item)
        } catch {
            // Rollback — put it back in the old lane.
            try? local.move(item, to: oldPriority)
            throw error
        }
    }

    func rolloverOverdueItems(to date: Date) async throws {
        try local.rolloverOverdueItems(to: date)
        let _: RolloverResponse = try await apiClient.request(
            .rollover(body: RolloverRequest(toDate: Self.dateFormatter.string(from: date)))
        )
    }

    func materializeRepeatingItems(for dateRange: ClosedRange<Date>) async throws {
        try local.materializeRepeatingItems(for: dateRange)
        let _: MaterializeResponse = try await apiClient.request(
            .materialize(body: MaterializeRequest(
                startDate: Self.dateFormatter.string(from: dateRange.lowerBound),
                endDate: Self.dateFormatter.string(from: dateRange.upperBound)
            ))
        )
    }

    func reschedule(_ item: TodoItem, to date: Date, resetCount: Bool) async throws {
        let oldDate = item.scheduledDate
        let oldCount = item.rescheduleCount
        try local.reschedule(item, to: date, resetCount: resetCount)
        do {
            let response: APITodoItem = try await apiClient.request(
                .rescheduleItem(id: item.id, body: RescheduleRequest(
                    toDate: Self.dateFormatter.string(from: date),
                    resetCount: resetCount
                ))
            )
            reconcile(server: response, into: item)
            try local.update(item)
        } catch {
            // Rollback the two fields the local reschedule touched.
            item.scheduledDate = oldDate
            item.rescheduleCount = oldCount
            try? local.update(item)
            throw error
        }
    }

    func deleteUndoneOccurrences(for repeatingID: UUID) throws {
        // Purely-local cleanup. The server performs its own cascade when the
        // parent repeating rule is DELETE'd; this method is called by
        // `LocalRepeatingRepository.delete` before the server round-trip to
        // keep the UI in sync. Nothing to push.
        try local.deleteUndoneOccurrences(for: repeatingID)
    }

    // MARK: - RepeatingRepository

    func fetchItems() throws -> [RepeatingItem] {
        try localRepeating.fetchItems()
    }

    func add(_ item: RepeatingItem) async throws {
        try localRepeating.add(item)
        do {
            let response: APIRepeatingItem = try await apiClient.request(
                .createRepeating(body: createRepeatingRequest(from: item))
            )
            reconcile(server: response, into: item)
            try localRepeating.update(item)
        } catch {
            try? localRepeating.delete(item)
            throw error
        }
    }

    func update(_ item: RepeatingItem) async throws {
        try localRepeating.update(item)
        do {
            let response: APIRepeatingItem = try await apiClient.request(
                .updateRepeating(id: item.id, body: updateRepeatingRequest(from: item))
            )
            reconcile(server: response, into: item)
            try localRepeating.update(item)
        } catch {
            throw error
        }
    }

    func delete(_ item: RepeatingItem) async throws {
        let id = item.id
        // Server-first: the server's delete handler cascades to linked
        // undone occurrences on its side. Local cascade runs from
        // `LocalRepeatingRepository.delete`.
        try await apiClient.requestNoContent(.deleteRepeating(id: id))
        try localRepeating.delete(item)
    }

    // MARK: - Reconciliation
    //
    // After a successful server mutation we adopt the server's
    // `updated_at` (and `completed_at` when the server set it) so the next
    // conflict check on that row uses the server's clock. We deliberately
    // DON'T overwrite user-facing fields — the user may have mutated them
    // again optimistically while the request was in flight.

    private func reconcile(server: APITodoItem, into item: TodoItem) {
        if let ts = server.updatedAt.flatMap({ DateFormatters.parseDateTime($0) }) {
            item.updatedAt = ts
        }
        if let ca = server.completedAt.flatMap({ DateFormatters.parseDateTime($0) }) {
            // Only adopt server-set completedAt when the local view still
            // considers the task done.
            if item.isDone { item.completedAt = ca }
        }
    }

    private func reconcile(server: APIRepeatingItem, into item: RepeatingItem) {
        if let ts = server.updatedAt.flatMap({ DateFormatters.parseDateTime($0) }) {
            item.updatedAt = ts
        }
    }

    // MARK: - Payload Builders

    private func createRequest(from item: TodoItem) -> CreateItemRequest {
        CreateItemRequest(
            id: item.id,
            title: item.title,
            priority: item.priorityRawValue,
            scheduledDate: Self.dateFormatter.string(from: item.scheduledDate),
            reminderDate: item.reminderDate.map { DateFormatters.iso8601DateTime.string(from: $0) },
            sortOrder: item.sortOrder,
            sourceRepeatingId: item.sourceRepeatingID,
            sourceRepeatingRuleName: item.sourceRepeatingRuleName
        )
    }

    private func updateRequest(from item: TodoItem) -> UpdateItemRequest {
        UpdateItemRequest(
            title: item.title,
            priority: item.priorityRawValue,
            isDone: item.isDone,
            sortOrder: item.sortOrder,
            reminderDate: item.reminderDate.map { DateFormatters.iso8601DateTime.string(from: $0) },
            scheduledDate: Self.dateFormatter.string(from: item.scheduledDate),
            rescheduleCount: item.rescheduleCount
            // No updatedAt: the server owns `updated_at`. The local
            // `item.updatedAt` is still adopted from server responses
            // (see `reconcile`) so the /sync delta engine has a
            // freshness anchor, but we never echo it back on writes.
            // See docs/conflict_resolution_redesign.md.
        )
    }

    private func createRepeatingRequest(from item: RepeatingItem) -> CreateRepeatingRequest {
        CreateRepeatingRequest(
            id: item.id,
            title: item.title,
            frequency: item.frequencyRawValue,
            scheduledTime: Self.dateFormatter.string(from: item.scheduledTime),
            scheduledDayOfWeek: item.scheduledDayOfWeek,
            scheduledDayOfMonth: item.scheduledDayOfMonth,
            scheduledMonth: item.scheduledMonth,
            sortOrder: item.sortOrder,
            defaultUrgency: item.defaultUrgencyRawValue
        )
    }

    private func updateRepeatingRequest(from item: RepeatingItem) -> UpdateRepeatingRequest {
        UpdateRepeatingRequest(
            title: item.title,
            frequency: item.frequencyRawValue,
            scheduledTime: Self.dateFormatter.string(from: item.scheduledTime),
            scheduledDayOfWeek: item.scheduledDayOfWeek,
            scheduledDayOfMonth: item.scheduledDayOfMonth,
            scheduledMonth: item.scheduledMonth,
            sortOrder: item.sortOrder,
            defaultUrgency: item.defaultUrgencyRawValue
            // See updateRequest(from:) — same redesign for repeating.
        )
    }
}
