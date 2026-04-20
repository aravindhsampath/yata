import Foundation
import SwiftData

@MainActor
final class CachingRepository: TodoRepository, RepeatingRepository {
    private let local: LocalTodoRepository
    private let localRepeating: LocalRepeatingRepository
    private let logger: MutationLogger

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(local: LocalTodoRepository, localRepeating: LocalRepeatingRepository, logger: MutationLogger) {
        self.local = local
        self.localRepeating = localRepeating
        self.logger = logger
    }

    // MARK: - TodoRepository (Read-only -- no logging)

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

    // MARK: - TodoRepository (Writes -- delegate + log)

    func add(_ item: TodoItem) throws {
        try local.add(item)
        try logger.log(
            entityType: "todoItem",
            entityID: item.id,
            mutationType: "create",
            payload: createRequest(from: item)
        )
    }

    func update(_ item: TodoItem) throws {
        try local.update(item)
        try logger.log(
            entityType: "todoItem",
            entityID: item.id,
            mutationType: "update",
            payload: updateRequest(from: item)
        )
    }

    func delete(_ item: TodoItem) throws {
        let entityID = item.id
        try local.delete(item)
        try logger.log(
            entityType: "todoItem",
            entityID: entityID,
            mutationType: "delete",
            payload: EmptyPayload()
        )
    }

    func reorder(ids: [UUID], in priority: Priority) throws {
        try local.reorder(ids: ids, in: priority)
        let syntheticID = Self.syntheticReorderID(for: priority)
        let today = Self.dateFormatter.string(from: Date.now)
        try logger.log(
            entityType: "todoItem",
            entityID: syntheticID,
            mutationType: "reorder",
            payload: ReorderRequest(date: today, priority: priority.rawValue, ids: ids)
        )
    }

    func move(_ item: TodoItem, to priority: Priority) throws {
        try local.move(item, to: priority)
        try logger.log(
            entityType: "todoItem",
            entityID: item.id,
            mutationType: "move",
            payload: MoveRequest(toPriority: priority.rawValue, atIndex: item.sortOrder)
        )
    }

    func rolloverOverdueItems(to date: Date) throws {
        try local.rolloverOverdueItems(to: date)
        let dateStr = Self.dateFormatter.string(from: date)
        try logger.log(
            entityType: "todoItem",
            entityID: Self.rolloverSyntheticID,
            mutationType: "rollover",
            payload: RolloverRequest(toDate: dateStr)
        )
    }

    func materializeRepeatingItems(for dateRange: ClosedRange<Date>) throws {
        try local.materializeRepeatingItems(for: dateRange)
        let startStr = Self.dateFormatter.string(from: dateRange.lowerBound)
        let endStr = Self.dateFormatter.string(from: dateRange.upperBound)
        try logger.log(
            entityType: "todoItem",
            entityID: Self.materializeSyntheticID,
            mutationType: "materialize",
            payload: MaterializeRequest(startDate: startStr, endDate: endStr)
        )
    }

    func reschedule(_ item: TodoItem, to date: Date, resetCount: Bool) throws {
        try local.reschedule(item, to: date, resetCount: resetCount)
        let dateStr = Self.dateFormatter.string(from: date)
        try logger.log(
            entityType: "todoItem",
            entityID: item.id,
            mutationType: "reschedule",
            payload: RescheduleRequest(toDate: dateStr, resetCount: resetCount)
        )
    }

    func deleteUndoneOccurrences(for repeatingID: UUID) throws {
        try local.deleteUndoneOccurrences(for: repeatingID)
        try logger.log(
            entityType: "todoItem",
            entityID: repeatingID,
            mutationType: "deleteOccurrences",
            payload: RepeatingIDPayload(repeatingId: repeatingID)
        )
    }

    // MARK: - RepeatingRepository

    func fetchItems() throws -> [RepeatingItem] {
        try localRepeating.fetchItems()
    }

    func add(_ item: RepeatingItem) throws {
        try localRepeating.add(item)
        try logger.log(
            entityType: "repeatingItem",
            entityID: item.id,
            mutationType: "create",
            payload: createRepeatingRequest(from: item)
        )
    }

    func update(_ item: RepeatingItem) throws {
        try localRepeating.update(item)
        try logger.log(
            entityType: "repeatingItem",
            entityID: item.id,
            mutationType: "update",
            payload: updateRepeatingRequest(from: item)
        )
    }

    func delete(_ item: RepeatingItem) throws {
        let entityID = item.id
        try localRepeating.delete(item)
        try logger.log(
            entityType: "repeatingItem",
            entityID: entityID,
            mutationType: "delete",
            payload: EmptyPayload()
        )
    }

    // MARK: - Payload Builders

    private func createRequest(from item: TodoItem) -> CreateItemRequest {
        CreateItemRequest(
            id: item.id,
            title: item.title,
            priority: item.priorityRawValue,
            scheduledDate: Self.dateFormatter.string(from: item.scheduledDate),
            reminderDate: item.reminderDate.map { Self.dateFormatter.string(from: $0) },
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
            rescheduleCount: item.rescheduleCount,
            // updated_at MUST be an ISO8601 timestamp matching the server's
            // stored RFC3339 value — the conflict check on the server compares
            // these two strings lexically. A date-only format (YYYY-MM-DD) is
            // always lexically less than an RFC3339 datetime, which makes
            // every update a false 409 conflict and discards the local change.
            updatedAt: item.updatedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
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
            defaultUrgency: item.defaultUrgencyRawValue,
            // See updateRequest above: ISO8601, not date-only, or the server
            // treats every update as a conflict.
            updatedAt: item.updatedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
        )
    }

    // MARK: - Synthetic IDs

    private static func syntheticReorderID(for priority: Priority) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-00000000000\(priority.rawValue)")!
    }

    private static let rolloverSyntheticID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private static let materializeSyntheticID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
}

// MARK: - Helper payloads

private struct EmptyPayload: Encodable {}

private struct RepeatingIDPayload: Encodable {
    let repeatingId: UUID
}
