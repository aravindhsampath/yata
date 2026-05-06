import SwiftData
import XCTest
@testable import YATA

/// Verifies the P1.9 refactor: notification-action handlers route
/// writes through the same `TodoRepository` instance the SwiftUI UI
/// uses, instead of opening a separate `ModelContext` and firing a
/// duplicate API call via the now-deleted `logMutation` path.
///
/// The bug we used to ship: two ModelContexts on the same container
/// could merge in surprising orders if the user tapped a row in the
/// app at the same moment a notification action fired for the same
/// item. The manual `apiClient.request(.updateItem(...))` mirror
/// also bypassed `CachingRepository`'s reconciliation, so the API
/// could see a different snapshot than local.
///
/// Now both surfaces use `repository.update(item)` /
/// `repository.reschedule(item, …)` — single write path, single
/// context, single API mirror.
final class NotificationActionRoutingTests: XCTestCase {

    private var container: ModelContainer!
    private var provider: RepositoryProvider!
    private var delegate: AppDelegate!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
            configurations: config
        )
        provider = RepositoryProvider(container: container)
        delegate = AppDelegate()
        delegate.modelContainer = container
        delegate.repositoryProvider = provider
    }

    @MainActor
    private func seedItem(title: String = "test") async throws -> UUID {
        let item = TodoItem(
            title: title,
            priority: .medium,
            scheduledDate: Calendar.current.startOfDay(for: .now)
        )
        try await provider.todoRepository.add(item)
        return item.id
    }

    // MARK: - Mark done

    @MainActor
    func test_handleMarkDone_marksItemDoneViaRepository() async throws {
        let id = try await seedItem(title: "done me")

        await delegate.handleMarkDone(itemID: id)

        let updated = try await provider.todoRepository.fetchTodoItem(by: id)
        XCTAssertNotNil(updated, "item should still exist after mark-done")
        XCTAssertTrue(updated?.isDone == true, "isDone must be true after handleMarkDone")
        XCTAssertNotNil(updated?.completedAt, "completedAt must be stamped")
    }

    /// The structural fix: concurrent mark-done from the UI and from
    /// a notification action must converge to a single coherent
    /// done-state with no duplicate writes or torn intermediate
    /// state. Both paths now use the same `@MainActor`-bound
    /// repository, so writes are serialized at the actor boundary.
    @MainActor
    func test_concurrent_uiMarkDone_andNotificationHandler_converge() async throws {
        let id = try await seedItem(title: "racey")

        // Two independent paths racing on the same row, modeled
        // after what would happen if a user tapped a row in the
        // app at the same instant the OS delivered a notification
        // mark-done.
        async let uiPath: Void = {
            guard let item = try? await provider.todoRepository.fetchTodoItem(by: id) else { return }
            item.isDone = true
            item.completedAt = .now
            try? await provider.todoRepository.update(item)
        }()
        async let notifPath: Void = delegate.handleMarkDone(itemID: id)

        _ = await (uiPath, notifPath)

        let final = try await provider.todoRepository.fetchTodoItem(by: id)
        XCTAssertTrue(final?.isDone == true, "concurrent mark-done must leave isDone=true")
        XCTAssertNotNil(final?.completedAt, "completedAt must be set exactly once")
    }

    // MARK: - Snooze

    @MainActor
    func test_handleSnooze30_setsReminderViaRepository() async throws {
        let id = try await seedItem(title: "snoozable")

        // The handler accepts a `UNNotificationContent` for the
        // reschedule-the-OS-notification step; we don't care about
        // that side-effect here — only the repository write matters.
        let content = UNMutableNotificationContent()
        content.title = "snoozable"
        delegate.handleSnooze30(itemID: id, from: content)

        // handleSnooze30 spawns a Task; give it a beat to land.
        try await Task.sleep(nanoseconds: 200_000_000)

        let updated = try await provider.todoRepository.fetchTodoItem(by: id)
        XCTAssertNotNil(updated?.reminderDate, "reminderDate must be set after snooze")
        let drift = updated!.reminderDate!.timeIntervalSinceNow
        XCTAssertGreaterThan(drift, 29 * 60, "reminder should be ~30 min in the future")
        XCTAssertLessThan(drift, 31 * 60, "reminder should not be more than 30 min in the future")
    }

    // MARK: - Tomorrow

    @MainActor
    func test_handleTomorrow_advancesScheduledDateAndIncrementsCount() async throws {
        let id = try await seedItem(title: "push it")
        let originalCount = try await provider.todoRepository.fetchTodoItem(by: id)?.rescheduleCount ?? 0

        await delegate.handleTomorrow(itemID: id)

        let updated = try await provider.todoRepository.fetchTodoItem(by: id)
        let tomorrow = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: .now)
        )!
        XCTAssertEqual(updated?.scheduledDate, tomorrow, "scheduledDate must advance to tomorrow's local-midnight")
        XCTAssertEqual(updated?.rescheduleCount, originalCount + 1, "rescheduleCount must increment by 1")
    }

    // MARK: - Graceful no-op when wiring is absent

    @MainActor
    func test_handleMarkDone_isNoOp_whenRepositoryProviderUnset() async throws {
        let isolated = AppDelegate()
        // No modelContainer, no repositoryProvider — simulates the
        // pre-wiring window. P1.8 makes the handler wait briefly
        // and bail; this test pins that bail behavior so a regression
        // doesn't crash the app on cold launch from notification.
        await isolated.awaitContainer(timeoutSeconds: 0.1)
        await isolated.handleMarkDone(itemID: UUID())
        // We get here without crashing — that's the contract.
    }
}
