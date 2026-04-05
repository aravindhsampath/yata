import Foundation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class HomeViewModel {
    private let repository: any TodoRepository

    var highItems: [TodoItem] = []
    var mediumItems: [TodoItem] = []
    var lowItems: [TodoItem] = []
    var doneItems: [TodoItem] = []
    var isLoading = false
    var editingItem: TodoItem?
    var addingToPriority: Priority?
    var errorMessage: String?
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // Calendar state
    var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    private(set) var weekDates: [Date] = []

    // Done list limit
    var doneListLimit: Int = 25

    // Week task counts for dot ring
    var weekTaskCounts: [Date: [Priority: Int]] = [:]

    // Progress tracking
    var todayDoneCount: Int = 0

    // Drop glow animation
    var justDroppedItemID: UUID?

    // Drag state
    var draggingItemID: UUID?
    var dropTarget: DropTarget?

    struct DropTarget: Equatable {
        let priority: Priority
        let index: Int
    }

    init(repository: any TodoRepository) {
        self.repository = repository
        refreshWeekDates()
    }

    func refreshWeekDates() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        weekDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var totalTodayCount: Int {
        highItems.count + mediumItems.count + lowItems.count + todayDoneCount
    }

    var progressFraction: Double {
        totalTodayCount > 0 ? Double(todayDoneCount) / Double(totalTodayCount) : 0
    }

    var progressLabel: String {
        if totalTodayCount == 0 { return "" }
        if todayDoneCount == totalTodayCount { return "All done for today" }
        return "\(todayDoneCount) of \(totalTodayCount) done today"
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            highItems = try await repository.fetchItems(for: selectedDate, priority: .high)
            mediumItems = try await repository.fetchItems(for: selectedDate, priority: .medium)
            lowItems = try await repository.fetchItems(for: selectedDate, priority: .low)
            doneItems = try await repository.fetchDoneItems(limit: doneListLimit)
            todayDoneCount = try await repository.countDoneItems(for: selectedDate)
            weekTaskCounts = try await repository.fetchTaskCountsByPriority(for: weekDates)
            // Sync notifications on load
            let allActiveItems = (highItems + mediumItems + lowItems)
            NotificationScheduler.syncAllReminders(items: allActiveItems)

            // Set badge to overdue reminder count
            let now = Date.now
            let overdueCount = allActiveItems.filter { ($0.reminderDate ?? .distantFuture) < now }.count
            try? await UNUserNotificationCenter.current().setBadgeCount(overdueCount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshWeekTaskCounts() async {
        do {
            weekTaskCounts = try await repository.fetchTaskCountsByPriority(for: weekDates)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDate(_ date: Date) async {
        selectedDate = Calendar.current.startOfDay(for: date)
        await materializeRepeatingItems()
        await loadAll()
    }

    func items(for priority: Priority) -> [TodoItem] {
        switch priority {
        case .high: highItems
        case .medium: mediumItems
        case .low: lowItems
        }
    }

    func markDone(_ item: TodoItem) async {
        item.isDone = true
        item.completedAt = .now
        do {
            try await repository.update(item)
            NotificationScheduler.cancelReminder(for: item.id)
            removeFromPriorityArray(item)
            doneItems.insert(item, at: 0)
            if doneItems.count > doneListLimit {
                doneItems.removeLast()
            }
            if Calendar.current.isDate(selectedDate, inSameDayAs: Calendar.current.startOfDay(for: .now)) {
                todayDoneCount += 1
            }
            await refreshWeekTaskCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markUndone(_ item: TodoItem) async {
        item.isDone = false
        item.completedAt = nil
        item.scheduledDate = selectedDate
        do {
            try await repository.update(item)
            doneItems.removeAll { $0.id == item.id }
            appendToPriorityArray(item)
            if Calendar.current.isDate(selectedDate, inSameDayAs: Calendar.current.startOfDay(for: .now)) {
                todayDoneCount = max(0, todayDoneCount - 1)
            }
            await refreshWeekTaskCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItem(title: String, priority: Priority, reminderDate: Date?) async {
        let count = items(for: priority).count
        let item = TodoItem(
            title: title,
            priority: priority,
            reminderDate: reminderDate,
            sortOrder: count,
            scheduledDate: selectedDate
        )
        do {
            try await repository.add(item)
            NotificationScheduler.scheduleReminder(for: item)
            appendToPriorityArray(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateItem(_ item: TodoItem) async {
        do {
            try await repository.update(item)
            NotificationScheduler.cancelReminder(for: item.id)
            NotificationScheduler.scheduleReminder(for: item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: TodoItem) async {
        do {
            try await repository.delete(item)
            NotificationScheduler.cancelReminder(for: item.id)
            removeFromPriorityArray(item)
            doneItems.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorder(ids: [UUID], in priority: Priority) async {
        do {
            try await repository.reorder(ids: ids, in: priority)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveItem(_ item: TodoItem, to priority: Priority) async {
        let sourcePriority = item.priority
        do {
            try await repository.move(item, to: priority)
            removeFromArray(for: sourcePriority, item: item)
            appendToArray(for: priority, item: item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDrop(itemID: UUID, toPriority: Priority, atIndex: Int) async {
        defer { draggingItemID = nil; dropTarget = nil }

        let allItems = Priority.allCases.flatMap { items(for: $0) }
        guard let item = allItems.first(where: { $0.id == itemID }) else { return }

        let sourcePriority = item.priority

        if sourcePriority == toPriority {
            var currentItems = items(for: toPriority)
            guard let fromIndex = currentItems.firstIndex(where: { $0.id == itemID }) else { return }
            let targetIndex = atIndex > fromIndex ? atIndex - 1 : atIndex
            currentItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: targetIndex > fromIndex ? targetIndex + 1 : targetIndex)
            setItems(currentItems, for: toPriority)
        } else {
            removeFromArray(for: sourcePriority, item: item)
            var targetItems = items(for: toPriority)
            let insertAt = min(atIndex, targetItems.count)
            item.priority = toPriority
            targetItems.insert(item, at: insertAt)
            setItems(targetItems, for: toPriority)
        }

        justDroppedItemID = itemID

        // Persist to database
        if sourcePriority == toPriority {
            let ids = items(for: toPriority).map(\.id)
            await reorder(ids: ids, in: toPriority)
        } else {
            do {
                try await repository.move(item, to: toPriority)
                let ids = items(for: toPriority).map(\.id)
                try await repository.reorder(ids: ids, in: toPriority)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        Task {
            try? await Task.sleep(for: .milliseconds(400))
            justDroppedItemID = nil
        }
    }

    func startDrag(itemID: UUID) {
        draggingItemID = itemID
    }

    func endDrag() {
        draggingItemID = nil
        dropTarget = nil
    }

    // MARK: - Rollover & Materialization

    var secondsUntilMidnight: TimeInterval {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        return max(1, tomorrow.timeIntervalSinceNow)
    }

    func performRollover() async {
        do {
            try await repository.rolloverOverdueItems(to: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func materializeRepeatingItems() async {
        guard let first = weekDates.first, let last = weekDates.last else { return }
        do {
            try await repository.materializeRepeatingItems(for: first...last)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescheduleItem(_ item: TodoItem, to date: Date) async {
        do {
            try await repository.reschedule(item, to: date, resetCount: true)
            NotificationScheduler.cancelReminder(for: item.id)
            NotificationScheduler.scheduleReminder(for: item)
            removeFromPriorityArray(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescheduleToTomorrow(_ item: TodoItem) async {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        do {
            try await repository.reschedule(item, to: tomorrow, resetCount: false)
            NotificationScheduler.cancelReminder(for: item.id)
            // Preserve time-of-day for the reminder on the new day
            if let oldReminder = item.reminderDate {
                let calendar = Calendar.current
                let timeComponents = calendar.dateComponents([.hour, .minute], from: oldReminder)
                item.reminderDate = calendar.date(bySettingHour: timeComponents.hour ?? 9,
                                                   minute: timeComponents.minute ?? 0,
                                                   second: 0, of: tomorrow)
                NotificationScheduler.scheduleReminder(for: item)
            }
            removeFromPriorityArray(item)
            await refreshWeekTaskCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Array helpers

    private func removeFromPriorityArray(_ item: TodoItem) {
        removeFromArray(for: item.priority, item: item)
    }

    private func appendToPriorityArray(_ item: TodoItem) {
        appendToArray(for: item.priority, item: item)
    }

    private func removeFromArray(for priority: Priority, item: TodoItem) {
        switch priority {
        case .high: highItems.removeAll { $0.id == item.id }
        case .medium: mediumItems.removeAll { $0.id == item.id }
        case .low: lowItems.removeAll { $0.id == item.id }
        }
    }

    private func appendToArray(for priority: Priority, item: TodoItem) {
        switch priority {
        case .high: highItems.append(item)
        case .medium: mediumItems.append(item)
        case .low: lowItems.append(item)
        }
    }

    private func setItems(_ items: [TodoItem], for priority: Priority) {
        switch priority {
        case .high: highItems = items
        case .medium: mediumItems = items
        case .low: lowItems = items
        }
    }
}
