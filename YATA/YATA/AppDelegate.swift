import UIKit
import UserNotifications
import SwiftData
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var modelContainer: ModelContainer?
    var repositoryProvider: RepositoryProvider?

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

        // Register background sync task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.aravindhsampath.yata.sync", using: nil) { task in
            self.handleBackgroundSync(task: task as! BGAppRefreshTask)
        }

        return true
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

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt
    }()

    @MainActor
    private func handleMarkDone(itemID: UUID) async {
        guard let container = modelContainer else { return }
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
            guard let container = modelContainer else { return }
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
        guard let container = modelContainer else { return }
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
            rescheduleCount: item.rescheduleCount,
            // ISO8601 timestamp matching server's RFC3339 — any other format
            // triggers false 409 conflicts on the server's string compare.
            updatedAt: item.updatedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
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
}
