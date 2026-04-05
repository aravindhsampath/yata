import UIKit
import UserNotifications
import SwiftData

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var modelContainer: ModelContainer?

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

    func applicationDidBecomeActive(_ application: UIApplication) {
        UNUserNotificationCenter.current().setBadgeCount(0)
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

    @MainActor
    private func handleMarkDone(itemID: UUID) {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<TodoItem> { $0.id == itemID }
        var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let item = try? context.fetch(descriptor).first else { return }
        item.isDone = true
        item.completedAt = .now
        try? context.save()

        NotificationScheduler.cancelReminder(for: itemID)
        NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
    }

    private func handleSnooze30(itemID: UUID, from content: UNNotificationContent) {
        let snoozeDate = Date.now.addingTimeInterval(30 * 60)

        let newContent = content.mutableCopy() as! UNMutableNotificationContent
        newContent.body = "Snoozed - \(newContent.title)"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: snoozeDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "\(NotificationScheduler.identifierPrefix)\(itemID.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: newContent, trigger: trigger)

        UNUserNotificationCenter.current().add(request)

        // Also update the reminderDate on the item to keep model consistent
        Task { @MainActor in
            guard let container = modelContainer else { return }
            let context = ModelContext(container)
            let predicate = #Predicate<TodoItem> { $0.id == itemID }
            var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first else { return }
            item.reminderDate = snoozeDate
            try? context.save()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        }
    }

    @MainActor
    private func handleTomorrow(itemID: UUID) {
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

        // Preserve time-of-day for the reminder
        if let oldReminder = item.reminderDate {
            let timeComponents = calendar.dateComponents([.hour, .minute], from: oldReminder)
            item.reminderDate = calendar.date(bySettingHour: timeComponents.hour ?? 9,
                                               minute: timeComponents.minute ?? 0,
                                               second: 0, of: tomorrow)
        }
        try? context.save()

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
}
