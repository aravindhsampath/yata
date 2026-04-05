import Foundation
import UserNotifications

struct NotificationScheduler {
    static let identifierPrefix = "yata-reminder-"

    private static let center = UNUserNotificationCenter.current()

    static func scheduleReminder(for item: TodoItem) {
        guard let reminderDate = item.reminderDate, reminderDate > Date.now else { return }

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = "\(item.priority.label) priority"
        content.body = bodyText(for: reminderDate)
        content.sound = .default
        content.categoryIdentifier = "TASK_REMINDER"
        content.userInfo = ["itemID": item.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminderDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "\(identifierPrefix)\(item.id.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request)
    }

    static func cancelReminder(for itemID: UUID) {
        let identifier = "\(identifierPrefix)\(itemID.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func cancelAllReminders() {
        center.getPendingNotificationRequests { requests in
            let yataIDs = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: yataIDs)
        }
    }

    static func syncAllReminders(items: [TodoItem]) {
        let now = Date.now
        let validItems = items.filter { !$0.isDone && ($0.reminderDate ?? .distantPast) > now }
        let expectedIDs = Set(validItems.map { "\(identifierPrefix)\($0.id.uuidString)" })

        center.getPendingNotificationRequests { pending in
            let pendingYataIDs = Set(
                pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            )

            // Cancel stale
            let stale = pendingYataIDs.subtracting(expectedIDs)
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(stale))
            }

            // Schedule missing
            let pendingItemUUIDs = Set(pendingYataIDs.map { $0.replacingOccurrences(of: identifierPrefix, with: "") })
            for item in validItems where !pendingItemUUIDs.contains(item.id.uuidString) {
                scheduleReminder(for: item)
            }
        }
    }

    // MARK: - Helpers

    private static func bodyText(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Scheduled for today"
        } else if Calendar.current.isDateInTomorrow(date) {
            return "Scheduled for tomorrow"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: .now)
        }
    }
}
