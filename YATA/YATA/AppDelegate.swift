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
    //
    // Every handler now routes its write through `repositoryProvider.repository`
    // — the SAME repository instance the SwiftUI UI uses. This is the
    // serialization fix from P1.9: pre-refactor we opened a fresh
    // `ModelContext(container)` per handler AND fired a duplicate write
    // via a private `logMutation` → `apiClient.updateItem` path. Two
    // distinct contexts on the same row could merge in surprising
    // orders, and the manual API mirror bypassed the repository's
    // reconciliation. Now both UI taps and notification taps converge
    // on `repository.update(item)` / `repository.reschedule(item, …)`,
    // which the CachingRepository implements as a single
    // local-then-server transaction in API mode and a pure-local
    // write in Local mode.

    @MainActor
    func handleMarkDone(itemID: UUID) async {
        // Wait for the container + provider to be wired before we
        // touch them (cold-launch-from-notification race; see P1.8).
        guard await awaitContainer() != nil,
              let repo = repositoryProvider?.todoRepository else { return }
        guard let item = try? await repo.fetchTodoItem(by: itemID) else { return }

        item.isDone = true
        item.completedAt = .now

        do {
            try await repo.update(item)
        } catch {
            // Swallowed by design — notification actions have no UI
            // to surface a write failure on. The next foreground sync
            // will reconcile any drift. This used to be a fire-and-
            // forget API call; now it's the repository's own
            // local-then-server flow with the same fallback.
        }

        NotificationScheduler.cancelReminder(for: itemID)
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
    }

    func handleSnooze30(itemID: UUID, from content: UNNotificationContent) {
        let snoozeDate = Date.now.addingTimeInterval(30 * 60)

        // Schedule the local notification first — independent of the
        // data-store write. This matches the previous behavior so a
        // race between the OS reschedule and our repository update
        // doesn't lose the reminder.
        if let newContent = content.mutableCopy() as? UNMutableNotificationContent {
            newContent.body = "Snoozed - \(newContent.title)"
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: snoozeDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "\(NotificationScheduler.identifierPrefix)\(itemID.uuidString)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: newContent,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }

        Task { @MainActor in
            guard await awaitContainer() != nil,
                  let repo = repositoryProvider?.todoRepository else { return }
            guard let item = try? await repo.fetchTodoItem(by: itemID) else { return }

            item.reminderDate = snoozeDate

            do {
                try await repo.update(item)
            } catch {
                // See handleMarkDone; same fire-and-forget rationale.
            }

            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        }
    }

    @MainActor
    func handleTomorrow(itemID: UUID) async {
        guard await awaitContainer() != nil,
              let repo = repositoryProvider?.todoRepository else { return }
        guard let item = try? await repo.fetchTodoItem(by: itemID) else { return }

        let calendar = Calendar.current
        let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: .now)
        )!

        // `repo.reschedule` advances scheduledDate, increments
        // rescheduleCount, and saves locally + mirrors to the server
        // in one shot. It does NOT touch reminderDate — we patch
        // that below with a follow-up `update` if a reminder was set.
        do {
            try await repo.reschedule(item, to: tomorrow, resetCount: false)
        } catch {
            return
        }

        if let oldReminder = item.reminderDate {
            let timeComponents = calendar.dateComponents([.hour, .minute], from: oldReminder)
            item.reminderDate = calendar.date(
                bySettingHour: timeComponents.hour ?? 9,
                minute: timeComponents.minute ?? 0,
                second: 0,
                of: tomorrow
            )
            try? await repo.update(item)
        }

        NotificationScheduler.cancelReminder(for: itemID)
        if item.reminderDate != nil {
            NotificationScheduler.scheduleReminder(for: item)
        }
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
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
