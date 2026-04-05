import UIKit
import UserNotifications
import SwiftData

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

        return true
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

    // MARK: - Mutation Logging

    /// Logs an update mutation for sync when in client mode.
    /// The item is saved locally via its own ModelContext first;
    /// this method only records the pending mutation for the SyncEngine.
    @MainActor
    private func logMutation(for item: TodoItem) {
        guard let logger = repositoryProvider?.mutationLogger else { return }
        let fmt = Self.dateFormatter
        let payload = UpdateItemRequest(
            title: item.title,
            priority: item.priorityRawValue,
            isDone: item.isDone,
            sortOrder: item.sortOrder,
            reminderDate: item.reminderDate.map { fmt.string(from: $0) },
            scheduledDate: fmt.string(from: item.scheduledDate),
            rescheduleCount: item.rescheduleCount,
            updatedAt: item.updatedAt.map { fmt.string(from: $0) }
        )
        try? logger.log(entityType: "todoItem", entityID: item.id, mutationType: "update", payload: payload)
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let yataDataDidChange = Notification.Name("yataDataDidChange")
}
