import Foundation
import SwiftData

// MARK: - SyncError

enum SyncError: Error {
    case authenticationRequired
    case networkUnavailable(underlying: Error)
    case pullFailed(underlying: Error)
    case syncHalted(consecutiveFailures: Int)
}

// MARK: - SyncStatus

enum SyncStatus {
    case ok
    case retrying(failures: Int, nextRetryIn: TimeInterval)
    case halted(failures: Int)
}

// MARK: - SyncEngine
//
// Pull-only sync coordinator for API (client) mode.
//
// Under write-through semantics the iOS app pushes every mutation
// immediately via CachingRepository — there is no per-mutation push queue
// for SyncEngine to drain. SyncEngine's job is purely cross-device
// reconciliation: fetch the server's delta since the last sync and apply
// it to the local cache, skipping nothing (the local cache has no pending
// writes to protect from overwrite).
//
// Triggers (from YATAApp / AppDelegate / NetworkMonitor):
//   - scenePhase becomes .active       → syncIfStale()
//   - network reconnects               → syncIfStale()
//   - BGAppRefreshTask fires           → syncIfStale()
//   - User taps "Sync now" in Settings → fullSync()
//   - User taps "Disconnect"           → fullSync() best-effort before teardown
actor SyncEngine {
    private let apiClient: APIClient
    /// ModelContainer is Sendable; ModelContext is not. We create a
    /// short-lived main-actor-bound context inside each MainActor.run.
    private let modelContainer: ModelContainer

    // MARK: - Backoff state (for pull failures)

    private var consecutiveFailures: Int = 0
    private var backoffSeconds: TimeInterval = 0
    private let maxBackoff: TimeInterval = 60
    private let maxConsecutiveFailures: Int = 10

    private var isSyncHalted: Bool { consecutiveFailures >= maxConsecutiveFailures }

    /// Timestamp of the last fullSync attempt (start, not completion).
    /// `syncIfStale` uses this to coalesce the three auto-fire triggers
    /// (scene-active, network-reconnect, BGAppRefresh).
    private var lastSyncAttemptAt: Date?

    init(apiClient: APIClient, modelContainer: ModelContainer) {
        self.apiClient = apiClient
        self.modelContainer = modelContainer
    }

    // MARK: - Public API

    func syncStatus() -> SyncStatus {
        if isSyncHalted { return .halted(failures: consecutiveFailures) }
        if consecutiveFailures > 0 {
            return .retrying(failures: consecutiveFailures, nextRetryIn: backoffSeconds)
        }
        return .ok
    }

    func resetBackoff() {
        consecutiveFailures = 0
        backoffSeconds = 0
    }

    /// Call `fullSync()` only if no attempt has started in the last
    /// `minInterval` seconds. Use this for auto-fire triggers.
    /// User-initiated flows (Sync now, disconnect) call `fullSync()`
    /// directly so user intent is never ignored.
    func syncIfStale(minInterval: TimeInterval = 30) async throws {
        if let last = lastSyncAttemptAt, Date.now.timeIntervalSince(last) < minInterval {
            return
        }
        try await fullSync()
    }

    /// Pull the server's delta since the last sync and apply it to the
    /// local cache. In write-through mode this is the only kind of sync —
    /// there's no push because writes are already server-confirmed before
    /// they become visible locally.
    func fullSync() async throws {
        lastSyncAttemptAt = .now

        if isSyncHalted {
            throw SyncError.syncHalted(consecutiveFailures: consecutiveFailures)
        }

        if backoffSeconds > 0 {
            try await Task.sleep(for: .seconds(backoffSeconds))
        }

        do {
            try await pull()
            consecutiveFailures = 0
            backoffSeconds = 0
        } catch let error as SyncError {
            // Auth/network errors propagate unchanged; they're triage
            // signals for the caller (e.g. force re-login on 401).
            throw error
        } catch {
            consecutiveFailures += 1
            backoffSeconds = min(pow(2.0, Double(consecutiveFailures - 1)), maxBackoff)
            throw SyncError.pullFailed(underlying: error)
        }
    }

    // MARK: - Pull

    private func pull() async throws {
        let timestamp = UserDefaults.standard.string(forKey: "yata_lastSyncTimestamp")
            ?? "1970-01-01T00:00:00Z"

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

        let container = modelContainer
        try await MainActor.run {
            let context = ModelContext(container)

            // Apply upserted TodoItems.
            for apiItem in response.items.upserted {
                let targetID = apiItem.id
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let existing = try context.fetch(descriptor).first {
                    applyServerTodoItem(apiItem, to: existing)
                } else {
                    context.insert(apiItem.toTodoItem())
                }
            }

            // Apply upserted RepeatingItems.
            for apiItem in response.repeating.upserted {
                let targetID = apiItem.id
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let existing = try context.fetch(descriptor).first {
                    applyServerRepeatingItem(apiItem, to: existing)
                } else {
                    context.insert(apiItem.toRepeatingItem())
                }
            }

            // Apply deleted TodoItem IDs.
            for deletedID in response.items.deleted {
                let targetID = deletedID
                let descriptor = FetchDescriptor<TodoItem>(
                    predicate: #Predicate<TodoItem> { $0.id == targetID }
                )
                if let item = try context.fetch(descriptor).first {
                    context.delete(item)
                }
            }

            // Apply deleted RepeatingItem IDs.
            for deletedID in response.repeating.deleted {
                let targetID = deletedID
                let descriptor = FetchDescriptor<RepeatingItem>(
                    predicate: #Predicate<RepeatingItem> { $0.id == targetID }
                )
                if let item = try context.fetch(descriptor).first {
                    context.delete(item)
                }
            }

            try context.save()
        }

        UserDefaults.standard.set(response.serverTime, forKey: "yata_lastSyncTimestamp")
    }

    // MARK: - Server → local field copies

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
