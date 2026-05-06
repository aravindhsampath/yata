import UIKit
import UserNotifications
import SwiftData
import BackgroundTasks

/// Tiny protocol so unit tests can substitute a mock for `BGTask`,
/// which is `final` and not publicly constructible. We only need the
/// completion signal — that's enough to verify our dispatch logic
/// (a real BGTask would also have `expirationHandler`, `identifier`,
/// etc., but those don't enter the dispatch decision).
@MainActor
protocol DispatchableTask: AnyObject {
    func setTaskCompleted(success: Bool)
}

extension BGTask: DispatchableTask {}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var modelContainer: ModelContainer?
    var repositoryProvider: RepositoryProvider?

    /// How long a notification-action handler will wait for
    /// `modelContainer` and `repositoryProvider` to be wired up.
    ///
    /// Why this exists: SwiftUI hands us those references from
    /// `YATAApp.body`'s `.onAppear`, which fires AFTER iOS has
    /// already delivered any pending `userNotificationCenter(_:didReceive:)`
    /// from a cold-launch-from-notification tap. The race window
    /// is small (typically <100ms) but real — pre-fix the handler
    /// silently bailed, so the user's tap on "Mark Done" did
    /// nothing.
    ///
    /// 5s is generous enough to absorb cold-launch slow paths
    /// (low memory at launch, big migration) without leaving the
    /// user staring at a stuck notification.
    private static let containerWaitTimeoutSeconds: Double = 5
    /// Internal poll interval for `awaitContainer` — small enough
    /// that a typical resolution feels instant, large enough that
    /// the busy loop is cheap.
    static let containerPollIntervalSeconds: Double = 0.05

    /// Suspend until `modelContainer` and `repositoryProvider` are
    /// both set, or the timeout elapses. Returns the container on
    /// success, nil on timeout. Callers should treat nil as "drop
    /// this action; the foreground sync will reconcile."
    ///
    /// `internal` (rather than private) so unit tests can drive it.
    func awaitContainer(
        timeoutSeconds: Double = AppDelegate.containerWaitTimeoutSeconds
    ) async -> ModelContainer? {
        if let container = modelContainer, repositoryProvider != nil {
            return container
        }
        let pollNs = UInt64(Self.containerPollIntervalSeconds * 1_000_000_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: pollNs)
            if let container = modelContainer, repositoryProvider != nil {
                return container
            }
        }
        return nil
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register notification categories
        let markDone = UNNotificationAction(
            identifier: "MARK_DONE",
            title: "Done"
        )
        let snooze30 = UNNotificationAction(
            identifier: "SNOOZE_30",
            title: "30 min"
        )
        let tomorrow = UNNotificationAction(
            identifier: "TOMORROW",
            title: "Tomorrow"
        )

        let taskCategory = UNNotificationCategory(
            identifier: "TASK_REMINDER",
            actions: [markDone, snooze30, tomorrow],
            intentIdentifiers: []
        )
        center.setNotificationCategories([taskCategory])

        // Register background sync task. Goes through `dispatch(task:)`
        // — which downcasts safely — instead of a force-cast in the
        // closure body. iOS is *supposed* to deliver a
        // `BGAppRefreshTask` for this identifier, but if it ever
        // delivers a sibling (`BGProcessingTask` etc., possibly via a
        // duplicate-registration bug or a future API change) the
        // force-cast crashes the app silently in the background. The
        // user opens YATA and finds a blank state with no clue why.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.aravindhsampath.yata.sync", using: nil) { [weak self] task in
            self?.dispatch(task: task)
        }

        return true
    }

    /// Generic entry point from the BGTaskScheduler closure. Tries to
    /// downcast to `BGAppRefreshTask`; on failure, marks the task as
    /// not completed (so iOS schedules the next attempt) and returns.
    /// Generic over `DispatchableTask` so unit tests can inject a
    /// mock — `BGTask` itself is final and not constructible in tests.
    func dispatch(task: any DispatchableTask) {
        if let refreshTask = task as? BGAppRefreshTask {
            handleBackgroundSync(task: refreshTask)
            return
        }
        // Wrong subclass for our identifier. Don't crash — let iOS
        // know the task didn't complete so the schedule survives.
        task.setTaskCompleted(success: false)
    }

    // MARK: - Background Sync

    func handleBackgroundSync(task: BGAppRefreshTask) {
        scheduleBackgroundSync()

        let syncTask = Task { @MainActor in
            try await repositoryProvider?.syncEngine?.syncIfStale()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        }

        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }

        Task {
            do {
                try await syncTask.value
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
    }

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: "com.aravindhsampath.yata.sync")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["itemID"] as? String,
              let itemID = UUID(uuidString: idString) else { return }

        switch response.actionIdentifier {
        case "MARK_DONE":
            await handleMarkDone(itemID: itemID)
        case "SNOOZE_30":
            handleSnooze30(itemID: itemID, from: response.notification.request.content)
        case "TOMORROW":
            await handleTomorrow(itemID: itemID)
        default:
            break
        }
    }

    // MARK: - Action Handlers

    /// Local-tz calendar-day formatter (see DateFormatters.dateOnly for
    /// the full rationale). Notification-action handlers mutate
    /// scheduledDate, then mirror to the server — they must use the same
    /// local-tz formatting every other write path uses or the user's
    /// local day drifts by one when they're east of GMT.
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    @MainActor
    private func handleMarkDone(itemID: UUID) async {
        // Wait for the container to be wired up before we read it.
        // Cold-launch-from-notification can deliver the action
        // before YATAApp's onAppear fires; pre-fix this method
        // silently bailed and the user's tap was lost.
        guard let container = await awaitContainer() else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<TodoItem> { $0.id == itemID }
        var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let item = try? context.fetch(descriptor).first else { return }
        item.isDone = true
        item.completedAt = .now
        try? context.save()

        logMutation(for: item)

        NotificationScheduler.cancelReminder(for: itemID)
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
    }

    private func handleSnooze30(itemID: UUID, from content: UNNotificationContent) {
        let snoozeDate = Date.now.addingTimeInterval(30 * 60)

        guard let newContent = content.mutableCopy() as? UNMutableNotificationContent else { return }
        newContent.body = "Snoozed - \(newContent.title)"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: snoozeDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "\(NotificationScheduler.identifierPrefix)\(itemID.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: newContent, trigger: trigger)

        UNUserNotificationCenter.current().add(request)

        Task { @MainActor in
            // See `handleMarkDone` — same cold-launch race window.
            guard let container = await awaitContainer() else { return }
            let context = ModelContext(container)
            let predicate = #Predicate<TodoItem> { $0.id == itemID }
            var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first else { return }
            item.reminderDate = snoozeDate
            try? context.save()

            logMutation(for: item)

            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        }
    }

    @MainActor
    private func handleTomorrow(itemID: UUID) async {
        // See `handleMarkDone` — same cold-launch race window.
        guard let container = await awaitContainer() else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<TodoItem> { $0.id == itemID }
        var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let item = try? context.fetch(descriptor).first else { return }

        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        item.scheduledDate = tomorrow
        item.rescheduleCount += 1

        if let oldReminder = item.reminderDate {
            let timeComponents = calendar.dateComponents([.hour, .minute], from: oldReminder)
            item.reminderDate = calendar.date(bySettingHour: timeComponents.hour ?? 9,
                                               minute: timeComponents.minute ?? 0,
                                               second: 0, of: tomorrow)
        }

        try? context.save()

        logMutation(for: item)

        NotificationScheduler.cancelReminder(for: itemID)
        if item.reminderDate != nil {
            NotificationScheduler.scheduleReminder(for: item)
        }
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
    }

    // MARK: - Server mirror for notification-action writes

    /// The three notification-action handlers (Mark Done / Snooze 30 /
    /// Tomorrow) mutate a TodoItem via a standalone ModelContext before
    /// the app is even fully spun up. In API (client) mode we need to
    /// mirror that write to the server immediately — otherwise the server
    /// state diverges from the local cache until the next pull.
    ///
    /// In Local mode this is a no-op (apiClient is nil).
    @MainActor
    private func logMutation(for item: TodoItem) {
        guard let client = repositoryProvider?.apiClient else { return }
        let body = UpdateItemRequest(
            title: item.title,
            priority: item.priorityRawValue,
            isDone: item.isDone,
            sortOrder: item.sortOrder,
            reminderDate: item.reminderDate.map { DateFormatters.iso8601DateTime.string(from: $0) },
            scheduledDate: Self.dateFormatter.string(from: item.scheduledDate),
            rescheduleCount: item.rescheduleCount
            // No updatedAt — server is authoritative. Notification-action
            // mutations were the worst offender for false 409s under the
            // old design (separate ModelContext, stale `item.updatedAt`).
            // See docs/conflict_resolution_redesign.md.
        )
        let id = item.id
        Task {
            // Fire-and-forget: notification actions don't have a UI to show
            // errors on. A pull on next foreground will catch any drift.
            do {
                let _: APITodoItem = try await client.request(.updateItem(id: id, body: body))
            } catch {
                // Intentionally swallowed; the item is already saved
                // locally, and the next /sync pull will reconcile.
            }
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let yataDataDidChange = Notification.Name("yataDataDidChange")
    /// Posted when an API call returns 401. Listeners (ContentView) drop
    /// the client mode and surface an alert prompting the user to log in
    /// again from Settings.
    static let yataSessionExpired = Notification.Name("yataSessionExpired")
}
