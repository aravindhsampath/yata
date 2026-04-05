import Foundation
import SwiftData

// MARK: - SyncError

enum SyncError: Error {
    case authenticationRequired
    case networkUnavailable(underlying: Error)
    case pushFailed(underlying: Error)
    case pullFailed(underlying: Error)
    case syncHalted(consecutiveFailures: Int)
}

// MARK: - SyncStatus

enum SyncStatus {
    case ok
    case retrying(failures: Int, nextRetryIn: TimeInterval)
    case halted(failures: Int)
}

// MARK: - MutationSnapshot

/// Value-type copy of PendingMutation fields that can safely cross actor boundaries.
/// SwiftData @Model objects are MainActor-bound and cannot be sent to other actors.
private struct MutationSnapshot {
    let id: UUID
    let entityType: String
    let entityID: UUID
    let mutationType: String
    let payload: Data
    let retryCount: Int
}

// MARK: - SyncEngine

actor SyncEngine {
    private let apiClient: APIClient
    private let mutationLogger: MutationLogger
    private let modelContext: ModelContext

    // MARK: - Backoff state

    private var consecutiveFailures: Int = 0
    private var backoffSeconds: TimeInterval = 0
    private let maxBackoff: TimeInterval = 60
    private let maxConsecutiveFailures: Int = 10

    private var isSyncHalted: Bool { consecutiveFailures >= maxConsecutiveFailures }

    private let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(apiClient: APIClient, mutationLogger: MutationLogger, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.mutationLogger = mutationLogger
        self.modelContext = modelContext
    }

    // MARK: - Public API

    func syncStatus() -> SyncStatus {
        if isSyncHalted { return .halted(failures: consecutiveFailures) }
        if consecutiveFailures > 0 { return .retrying(failures: consecutiveFailures, nextRetryIn: backoffSeconds) }
        return .ok
    }

    func resetBackoff() {
        consecutiveFailures = 0
        backoffSeconds = 0
    }

    func push() async throws {
        // Check if sync is halted due to too many failures
        if isSyncHalted {
            throw SyncError.syncHalted(consecutiveFailures: consecutiveFailures)
        }

        // Wait for backoff period if needed
        if backoffSeconds > 0 {
            try await Task.sleep(for: .seconds(backoffSeconds))
        }

        // 1. Compact the queue
        try await MainActor.run { try mutationLogger.compact() }

        // 2. Fetch pending mutations and copy to value types
        let snapshots: [MutationSnapshot] = try await MainActor.run {
            let mutations = try mutationLogger.pendingMutations()
            return mutations.map { m in
                MutationSnapshot(
                    id: m.id,
                    entityType: m.entityType,
                    entityID: m.entityID,
                    mutationType: m.mutationType,
                    payload: m.payload,
                    retryCount: m.retryCount
                )
            }
        }

        // 3. Process each mutation in order
        for snapshot in snapshots {
            do {
                try await processMutation(snapshot)
            } catch let error as APIError {
                switch error {
                case .unauthorized:
                    throw SyncError.authenticationRequired
                case .networkError(let underlying):
                    throw SyncError.networkUnavailable(underlying: underlying)
                case .conflict(let serverData):
                    try await handleConflict(snapshot: snapshot, serverData: serverData)
                case .notFound:
                    try await handleNotFound(snapshot: snapshot)
                default:
                    // Increment retry count and record error
                    let mutationID = snapshot.id
                    try await MainActor.run {
                        let descriptor = FetchDescriptor<PendingMutation>(
                            predicate: #Predicate<PendingMutation> { $0.id == mutationID }
                        )
                        if let mutation = try modelContext.fetch(descriptor).first {
                            mutation.retryCount += 1
                            mutation.lastError = error.localizedDescription
                            try modelContext.save()
                        }
                    }
                    // Track consecutive failures for backoff
                    consecutiveFailures += 1
                    backoffSeconds = min(pow(2.0, Double(consecutiveFailures - 1)), maxBackoff)
                    throw SyncError.pushFailed(underlying: error)
                }
            }
        }

        // All mutations processed successfully — reset backoff
        consecutiveFailures = 0
        backoffSeconds = 0
    }

    func pull() async throws {
        // 1. Read lastSyncTimestamp
        let timestamp = UserDefaults.standard.string(forKey: "yata_lastSyncTimestamp") ?? "1970-01-01T00:00:00Z"

        // 2. Call the sync API
        let response: SyncResponse
        do {
            response = try await apiClient.request(.sync(since: timestamp))
        } catch let error as APIError {
            switch error {
            case .unauthorized:
                throw SyncError.authenticationRequired
            case .networkError(let underlying):
                throw SyncError.networkUnavailable(underlying: underlying)
            default:
                throw SyncError.pullFailed(underlying: error)
            }
        }

        // 3-8. Apply changes on MainActor
        try await MainActor.run {
            // 3. Collect entity IDs with pending mutations
            let pendingMutations = try mutationLogger.pendingMutations()
            let pendingEntityIDs = Set(pendingMutations.map(\.entityID))

            // 4. Apply upserted TodoItems
            for apiItem in response.items.upserted {
                guard !pendingEntityIDs.contains(apiItem.id) else { continue }

                let targetID = apiItem.id
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    applyServerTodoItem(apiItem, to: existing)
                } else {
                    modelContext.insert(apiItem.toTodoItem())
                }
            }

            // 5. Apply upserted RepeatingItems
            for apiItem in response.repeating.upserted {
                guard !pendingEntityIDs.contains(apiItem.id) else { continue }

                let targetID = apiItem.id
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    applyServerRepeatingItem(apiItem, to: existing)
                } else {
                    modelContext.insert(apiItem.toRepeatingItem())
                }
            }

            // 6. Apply deleted TodoItem IDs
            for deletedID in response.items.deleted {
                let targetID = deletedID
                let todoDescriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let item = try modelContext.fetch(todoDescriptor).first {
                    modelContext.delete(item)
                }
                // Also delete any pending mutations for this entity
                let mutationDescriptor = FetchDescriptor<PendingMutation>(
                    predicate: #Predicate<PendingMutation> { $0.entityID == targetID }
                )
                for mutation in try modelContext.fetch(mutationDescriptor) {
                    modelContext.delete(mutation)
                }
            }

            // 7. Apply deleted RepeatingItem IDs
            for deletedID in response.repeating.deleted {
                let targetID = deletedID
                let repeatingDescriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let item = try modelContext.fetch(repeatingDescriptor).first {
                    modelContext.delete(item)
                }
                let mutationDescriptor = FetchDescriptor<PendingMutation>(
                    predicate: #Predicate<PendingMutation> { $0.entityID == targetID }
                )
                for mutation in try modelContext.fetch(mutationDescriptor) {
                    modelContext.delete(mutation)
                }
            }

            // 8. Save
            try modelContext.save()
        }

        // 9. Store serverTime
        UserDefaults.standard.set(response.serverTime, forKey: "yata_lastSyncTimestamp")
    }

    func fullSync() async throws {
        do {
            try await push()
        } catch let error as SyncError {
            switch error {
            case .authenticationRequired, .networkUnavailable:
                throw error
            case .syncHalted:
                throw error
            case .pushFailed, .pullFailed:
                // Partial push failure — still attempt pull
                try await pull()
                return
            }
        }
        try await pull()
    }

    // MARK: - Private: Process a single mutation

    private func processMutation(_ snapshot: MutationSnapshot) async throws {
        let endpoint = try endpointFor(snapshot)
        let isNoContent = snapshot.entityType == "todoItem" && snapshot.mutationType == "delete"
            || snapshot.entityType == "repeatingItem" && snapshot.mutationType == "delete"

        if isNoContent {
            try await apiClient.requestNoContent(endpoint)
            try await deleteMutationByID(snapshot.id)
            return
        }

        // Rollover and materialize: no local entity to update
        if snapshot.mutationType == "rollover" {
            let _: RolloverResponse = try await apiClient.request(endpoint)
            try await deleteMutationByID(snapshot.id)
            return
        }
        if snapshot.mutationType == "materialize" {
            let _: MaterializeResponse = try await apiClient.request(endpoint)
            try await deleteMutationByID(snapshot.id)
            return
        }

        // Reorder: returns multiple items
        if snapshot.mutationType == "reorder" {
            let response: ItemsResponse = try await apiClient.request(endpoint)
            try await MainActor.run {
                for apiItem in response.items {
                    let targetID = apiItem.id
                    let descriptor = FetchDescriptor<TodoItem>(
                        predicate: #Predicate<TodoItem> { $0.id == targetID }
                    )
                    if let existing = try modelContext.fetch(descriptor).first {
                        existing.updatedAt = apiItem.updatedAt.flatMap { DateFormatters.parseDateTime($0) }
                    } else {
                        modelContext.insert(apiItem.toTodoItem())
                    }
                }
                try modelContext.save()
            }
            try await deleteMutationByID(snapshot.id)
            return
        }

        // Standard single-entity responses
        if snapshot.entityType == "todoItem" {
            let apiItem: APITodoItem = try await apiClient.request(endpoint)
            try await MainActor.run {
                let targetID = snapshot.entityID
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    existing.updatedAt = apiItem.updatedAt.flatMap { DateFormatters.parseDateTime($0) }
                }
                try modelContext.save()
            }
        } else if snapshot.entityType == "repeatingItem" {
            let apiItem: APIRepeatingItem = try await apiClient.request(endpoint)
            try await MainActor.run {
                let targetID = snapshot.entityID
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    existing.updatedAt = apiItem.updatedAt.flatMap { DateFormatters.parseDateTime($0) }
                }
                try modelContext.save()
            }
        }

        try await deleteMutationByID(snapshot.id)
    }

    // MARK: - Private: Endpoint mapping

    private func endpointFor(_ snapshot: MutationSnapshot) throws -> Endpoint {
        let entityType = snapshot.entityType
        let mutationType = snapshot.mutationType
        let payload = snapshot.payload
        let entityID = snapshot.entityID

        // Decode the snake_case JSON payload into a dictionary
        let d = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]

        switch (entityType, mutationType) {
        case ("todoItem", "create"):
            return .createItem(body: CreateItemRequest(
                id: uuid(d, "id") ?? entityID,
                title: str(d, "title"),
                priority: int(d, "priority"),
                scheduledDate: str(d, "scheduled_date"),
                reminderDate: d["reminder_date"] as? String,
                sortOrder: int(d, "sort_order"),
                sourceRepeatingId: uuid(d, "source_repeating_id"),
                sourceRepeatingRuleName: d["source_repeating_rule_name"] as? String
            ))

        case ("todoItem", "update"):
            return .updateItem(id: entityID, body: UpdateItemRequest(
                title: str(d, "title"),
                priority: int(d, "priority"),
                isDone: (d["is_done"] as? Bool) ?? false,
                sortOrder: int(d, "sort_order"),
                reminderDate: d["reminder_date"] as? String,
                scheduledDate: str(d, "scheduled_date"),
                rescheduleCount: int(d, "reschedule_count"),
                updatedAt: d["updated_at"] as? String
            ))

        case ("todoItem", "delete"):
            return .deleteItem(id: entityID)

        case ("todoItem", "reorder"):
            let uuidStrings = (d["ids"] as? [String]) ?? []
            return .reorderItems(body: ReorderRequest(
                date: str(d, "date"),
                priority: int(d, "priority"),
                ids: uuidStrings.compactMap { UUID(uuidString: $0) }
            ))

        case ("todoItem", "move"):
            return .moveItem(id: entityID, body: MoveRequest(
                toPriority: int(d, "to_priority"),
                atIndex: int(d, "at_index")
            ))

        case ("todoItem", "done"):
            return .markDone(id: entityID)

        case ("todoItem", "undone"):
            return .markUndone(id: entityID, body: UndoneRequest(
                scheduledDate: str(d, "scheduled_date")
            ))

        case ("todoItem", "reschedule"):
            return .rescheduleItem(id: entityID, body: RescheduleRequest(
                toDate: str(d, "to_date"),
                resetCount: (d["reset_count"] as? Bool) ?? false
            ))

        case ("todoItem", "rollover"):
            return .rollover(body: RolloverRequest(
                toDate: str(d, "to_date")
            ))

        case ("todoItem", "materialize"):
            return .materialize(body: MaterializeRequest(
                startDate: str(d, "start_date"),
                endDate: str(d, "end_date")
            ))

        case ("repeatingItem", "create"):
            return .createRepeating(body: CreateRepeatingRequest(
                id: uuid(d, "id") ?? entityID,
                title: str(d, "title"),
                frequency: int(d, "frequency"),
                scheduledTime: str(d, "scheduled_time"),
                scheduledDayOfWeek: d["scheduled_day_of_week"] as? Int,
                scheduledDayOfMonth: d["scheduled_day_of_month"] as? Int,
                scheduledMonth: d["scheduled_month"] as? Int,
                sortOrder: int(d, "sort_order"),
                defaultUrgency: int(d, "default_urgency")
            ))

        case ("repeatingItem", "update"):
            return .updateRepeating(id: entityID, body: UpdateRepeatingRequest(
                title: str(d, "title"),
                frequency: int(d, "frequency"),
                scheduledTime: str(d, "scheduled_time"),
                scheduledDayOfWeek: d["scheduled_day_of_week"] as? Int,
                scheduledDayOfMonth: d["scheduled_day_of_month"] as? Int,
                scheduledMonth: d["scheduled_month"] as? Int,
                sortOrder: int(d, "sort_order"),
                defaultUrgency: int(d, "default_urgency"),
                updatedAt: d["updated_at"] as? String
            ))

        case ("repeatingItem", "delete"):
            return .deleteRepeating(id: entityID)

        default:
            throw APIError.invalidURL
        }
    }

    // MARK: - Dictionary extraction helpers

    private func str(_ d: [String: Any], _ key: String) -> String {
        (d[key] as? String) ?? ""
    }

    private func int(_ d: [String: Any], _ key: String) -> Int {
        (d[key] as? Int) ?? 0
    }

    private func uuid(_ d: [String: Any], _ key: String) -> UUID? {
        guard let s = d[key] as? String else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: - Private: Helpers

    private func deleteMutationByID(_ mutationID: UUID) async throws {
        try await MainActor.run {
            let descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate<PendingMutation> { $0.id == mutationID }
            )
            if let mutation = try modelContext.fetch(descriptor).first {
                try mutationLogger.deleteMutation(mutation)
            }
        }
    }

    @MainActor
    private func applyServerTodoItem(_ apiItem: APITodoItem, to existing: TodoItem) {
        existing.title = apiItem.title
        existing.priorityRawValue = apiItem.priority
        existing.isDone = apiItem.isDone
        existing.sortOrder = apiItem.sortOrder
        existing.reminderDate = apiItem.reminderDate.flatMap { DateFormatters.parseDateTime($0) }
        existing.createdAt = DateFormatters.parseDateTime(apiItem.createdAt) ?? existing.createdAt
        existing.completedAt = apiItem.completedAt.flatMap { DateFormatters.parseDateTime($0) }
        existing.scheduledDate = DateFormatters.dateOnly.date(from: apiItem.scheduledDate) ?? existing.scheduledDate
        existing.sourceRepeatingID = apiItem.sourceRepeatingId
        existing.sourceRepeatingRuleName = apiItem.sourceRepeatingRuleName
        existing.rescheduleCount = apiItem.rescheduleCount
        existing.updatedAt = apiItem.updatedAt.flatMap { DateFormatters.parseDateTime($0) }
    }

    @MainActor
    private func applyServerRepeatingItem(_ apiItem: APIRepeatingItem, to existing: RepeatingItem) {
        existing.title = apiItem.title
        existing.frequencyRawValue = apiItem.frequency
        existing.scheduledTime = DateFormatters.timeOnly.date(from: apiItem.scheduledTime) ?? existing.scheduledTime
        existing.scheduledDayOfWeek = apiItem.scheduledDayOfWeek
        existing.scheduledDayOfMonth = apiItem.scheduledDayOfMonth
        existing.scheduledMonth = apiItem.scheduledMonth
        existing.sortOrder = apiItem.sortOrder
        existing.defaultUrgencyRawValue = apiItem.defaultUrgency
        existing.updatedAt = apiItem.updatedAt.flatMap { DateFormatters.parseDateTime($0) }
    }
}

// MARK: - Conflict and 404 handling extension

extension SyncEngine {
    /// Called from push() error handling when a 409 conflict is received.
    /// The serverData is the full HTTP response body: `{"error":{"code":"conflict","message":"...","server_version":{...}}}`.
    /// We extract `server_version` and decode it as the appropriate entity type.
    fileprivate func handleConflict(snapshot: MutationSnapshot, serverData: Data) async throws {
        // Extract server_version from the error envelope
        let serverVersionData: Data
        if let envelope = try? JSONSerialization.jsonObject(with: serverData) as? [String: Any],
           let errorObj = envelope["error"] as? [String: Any],
           let serverVersion = errorObj["server_version"] {
            serverVersionData = try JSONSerialization.data(withJSONObject: serverVersion)
        } else {
            // Fallback: try treating the entire body as the entity
            serverVersionData = serverData
        }

        if snapshot.entityType == "todoItem" {
            let apiItem = try payloadDecoder.decode(APITodoItem.self, from: serverVersionData)
            try await MainActor.run {
                let targetID = snapshot.entityID
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    applyServerTodoItem(apiItem, to: existing)
                    try modelContext.save()
                }
            }
        } else if snapshot.entityType == "repeatingItem" {
            let apiItem = try payloadDecoder.decode(APIRepeatingItem.self, from: serverVersionData)
            try await MainActor.run {
                let targetID = snapshot.entityID
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    applyServerRepeatingItem(apiItem, to: existing)
                    try modelContext.save()
                }
            }
        }
        try await deleteMutationByID(snapshot.id)
    }

    /// Called from push() error handling when a 404 is received
    fileprivate func handleNotFound(snapshot: MutationSnapshot) async throws {
        try await MainActor.run {
            let targetID = snapshot.entityID
            if snapshot.entityType == "todoItem" {
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let item = try modelContext.fetch(descriptor).first {
                    modelContext.delete(item)
                    try modelContext.save()
                }
            } else if snapshot.entityType == "repeatingItem" {
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let item = try modelContext.fetch(descriptor).first {
                    modelContext.delete(item)
                    try modelContext.save()
                }
            }
        }
        try await deleteMutationByID(snapshot.id)
    }
}

