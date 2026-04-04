import Testing
import SwiftData
import Foundation
@testable import YATA

@MainActor
@Suite("LocalTodoRepository")
struct LocalTodoRepositoryTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TodoItem.self, RepeatingItem.self, configurations: config)
    }

    private func makeRepo(_ container: ModelContainer) -> LocalTodoRepository {
        LocalTodoRepository(modelContainer: container)
    }

    // MARK: - Date-Scoped Queries

    @Test("fetchItems returns only items for the given date and priority")
    func fetchItemsByDateAndPriority() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)

        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let item1 = TodoItem(title: "Today high", priority: .high, scheduledDate: today)
        let item2 = TodoItem(title: "Today low", priority: .low, scheduledDate: today)
        let item3 = TodoItem(title: "Tomorrow high", priority: .high, scheduledDate: tomorrow)

        try repo.add(item1)
        try repo.add(item2)
        try repo.add(item3)

        let todayHigh = try repo.fetchItems(for: today, priority: .high)
        #expect(todayHigh.count == 1)
        #expect(todayHigh.first?.title == "Today high")

        let todayLow = try repo.fetchItems(for: today, priority: .low)
        #expect(todayLow.count == 1)
        #expect(todayLow.first?.title == "Today low")

        let tomorrowHigh = try repo.fetchItems(for: tomorrow, priority: .high)
        #expect(tomorrowHigh.count == 1)
        #expect(tomorrowHigh.first?.title == "Tomorrow high")
    }

    @Test("fetchDoneItems respects limit and sorts by completedAt descending")
    func fetchDoneItemsWithLimit() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)

        for i in 1...5 {
            let item = TodoItem(title: "Done \(i)", priority: .medium)
            item.isDone = true
            item.completedAt = Calendar.current.date(byAdding: .hour, value: i, to: .now)
            try repo.add(item)
        }

        let limited = try repo.fetchDoneItems(limit: 3)
        #expect(limited.count == 3)
        #expect(limited.first?.title == "Done 5") // most recent
    }

    // MARK: - Rollover

    @Test("rollover moves overdue undone items to today")
    func rolloverBasic() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let item = TodoItem(title: "Overdue", priority: .high, scheduledDate: yesterday)
        try repo.add(item)

        try repo.rolloverOverdueItems(to: .now)

        let items = try repo.fetchItems(for: today, priority: .high)
        #expect(items.count == 1)
        #expect(items.first?.rescheduleCount == 1)
    }

    @Test("rollover increments by actual days overdue, not just 1")
    func rolloverMultiDayGap() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let fiveDaysAgo = calendar.date(byAdding: .day, value: -5, to: today)!

        let item = TodoItem(title: "Very overdue", priority: .medium, scheduledDate: fiveDaysAgo)
        try repo.add(item)

        try repo.rolloverOverdueItems(to: .now)

        let items = try repo.fetchItems(for: today, priority: .medium)
        #expect(items.count == 1)
        #expect(items.first?.rescheduleCount == 5)
    }

    @Test("rollover does not touch done items")
    func rolloverSkipsDoneItems() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let item = TodoItem(title: "Done yesterday", priority: .high, scheduledDate: yesterday)
        item.isDone = true
        item.completedAt = yesterday
        try repo.add(item)

        try repo.rolloverOverdueItems(to: .now)

        // Should not appear in today's items
        let items = try repo.fetchItems(for: today, priority: .high)
        #expect(items.isEmpty)
    }

    @Test("rollover does not touch items scheduled for today or future")
    func rolloverSkipsFutureItems() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let todayItem = TodoItem(title: "Today", priority: .high, scheduledDate: today)
        let futureItem = TodoItem(title: "Tomorrow", priority: .high, scheduledDate: tomorrow)
        try repo.add(todayItem)
        try repo.add(futureItem)

        try repo.rolloverOverdueItems(to: .now)

        #expect(todayItem.rescheduleCount == 0)
        #expect(futureItem.rescheduleCount == 0)
    }

    // MARK: - Materialization

    @Test("materialize creates occurrences for daily rule")
    func materializeDailyRule() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: today)!

        let ctx = ModelContext(container)
        let rule = RepeatingItem(
            title: "Daily task",
            frequency: .daily,
            scheduledTime: .now,
            defaultUrgency: .high
        )
        ctx.insert(rule)
        try ctx.save()

        try repo.materializeRepeatingItems(for: today...endOfWeek)

        // Should create 7 occurrences (today + 6 days)
        var totalCount = 0
        for dayOffset in 0...6 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let items = try repo.fetchItems(for: date, priority: .high)
            totalCount += items.count
        }
        #expect(totalCount == 7)
    }

    @Test("materialize does not create duplicates on second run")
    func materializeIdempotent() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: today)!

        let ctx = ModelContext(container)
        let rule = RepeatingItem(
            title: "Daily task",
            frequency: .daily,
            scheduledTime: .now,
            defaultUrgency: .medium
        )
        ctx.insert(rule)
        try ctx.save()

        try repo.materializeRepeatingItems(for: today...endOfWeek)
        try repo.materializeRepeatingItems(for: today...endOfWeek) // second run

        var totalCount = 0
        for dayOffset in 0...6 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let items = try repo.fetchItems(for: date, priority: .medium)
            totalCount += items.count
        }
        #expect(totalCount == 7) // still 7, not 14
    }

    @Test("materialize uses rule's defaultUrgency for spawned items")
    func materializeUsesDefaultUrgency() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let ctx = ModelContext(container)
        let rule = RepeatingItem(
            title: "Low urgency task",
            frequency: .daily,
            scheduledTime: .now,
            defaultUrgency: .low
        )
        ctx.insert(rule)
        try ctx.save()

        try repo.materializeRepeatingItems(for: today...today)

        let lowItems = try repo.fetchItems(for: today, priority: .low)
        let highItems = try repo.fetchItems(for: today, priority: .high)
        #expect(lowItems.count == 1)
        #expect(highItems.isEmpty)
    }

    @Test("materialize weekly rule fires only on correct day")
    func materializeWeeklyRule() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: today)!

        let ctx = ModelContext(container)
        // Schedule for Wednesday (weekday = 4)
        let rule = RepeatingItem(
            title: "Weekly wednesday",
            frequency: .weekly,
            scheduledTime: .now,
            scheduledDayOfWeek: 4,
            defaultUrgency: .high
        )
        ctx.insert(rule)
        try ctx.save()

        try repo.materializeRepeatingItems(for: today...endOfWeek)

        // Count how many Wednesdays are in the range
        var expectedCount = 0
        for dayOffset in 0...6 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            if calendar.component(.weekday, from: date) == 4 {
                expectedCount += 1
            }
        }

        var actualCount = 0
        for dayOffset in 0...6 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let items = try repo.fetchItems(for: date, priority: .high)
            actualCount += items.count
        }
        #expect(actualCount == expectedCount)
    }

    // MARK: - Reschedule

    @Test("reschedule moves item to new date and resets count")
    func rescheduleBasic() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!

        let item = TodoItem(title: "Move me", priority: .high, scheduledDate: today)
        item.rescheduleCount = 3
        try repo.add(item)

        try repo.reschedule(item, to: nextWeek, resetCount: true)

        let todayItems = try repo.fetchItems(for: today, priority: .high)
        let nextWeekItems = try repo.fetchItems(for: nextWeek, priority: .high)
        #expect(todayItems.isEmpty)
        #expect(nextWeekItems.count == 1)
        #expect(nextWeekItems.first?.rescheduleCount == 0)
    }

    @Test("reschedule to same date does not reset rescheduleCount")
    func rescheduleToSameDate() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item = TodoItem(title: "Stay here", priority: .high, scheduledDate: today)
        item.rescheduleCount = 3
        try repo.add(item)

        try repo.reschedule(item, to: today, resetCount: true)

        #expect(item.rescheduleCount == 3) // preserved
    }

    // MARK: - Orphan Cleanup

    @Test("deleteUndoneOccurrences removes only undone items for given rule")
    func orphanCleanup() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)
        let ruleID = UUID()

        let undone = TodoItem(title: "Undone occurrence", priority: .high, scheduledDate: today, sourceRepeatingID: ruleID)
        let done = TodoItem(title: "Done occurrence", priority: .high, scheduledDate: today, sourceRepeatingID: ruleID)
        done.isDone = true
        done.completedAt = .now
        let manual = TodoItem(title: "Manual item", priority: .high, scheduledDate: today)

        try repo.add(undone)
        try repo.add(done)
        try repo.add(manual)

        try repo.deleteUndoneOccurrences(for: ruleID)

        let items = try repo.fetchItems(for: today, priority: .high)
        #expect(items.count == 1)
        #expect(items.first?.title == "Manual item")

        let doneItems = try repo.fetchDoneItems(limit: 10)
        #expect(doneItems.count == 1)
        #expect(doneItems.first?.title == "Done occurrence")
    }

    // MARK: - Workday Materialization

    @Test("materialize workday rule skips weekends")
    func materializeWorkdayRule() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current

        // Find a Monday to start from for deterministic testing
        var monday = calendar.startOfDay(for: .now)
        while calendar.component(.weekday, from: monday) != 2 {
            monday = calendar.date(byAdding: .day, value: 1, to: monday)!
        }
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)! // Mon-Sun = 7 days

        let ctx = ModelContext(container)
        let rule = RepeatingItem(
            title: "Workday only",
            frequency: .everyWorkday,
            scheduledTime: .now,
            defaultUrgency: .high
        )
        ctx.insert(rule)
        try ctx.save()

        try repo.materializeRepeatingItems(for: monday...sunday)

        var count = 0
        for dayOffset in 0...6 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: monday)!
            let items = try repo.fetchItems(for: date, priority: .high)
            count += items.count
        }
        #expect(count == 5) // Mon-Fri only
    }

    // MARK: - Reschedule Without Reset (swipe-right)

    @Test("reschedule without reset increments rescheduleCount")
    func rescheduleWithoutReset() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let item = TodoItem(title: "Defer me", priority: .high, scheduledDate: today)
        item.rescheduleCount = 2
        try repo.add(item)

        try repo.reschedule(item, to: tomorrow, resetCount: false)

        #expect(item.rescheduleCount == 3)
        #expect(calendar.isDate(item.scheduledDate, inSameDayAs: tomorrow))
    }

    // MARK: - Task Counts by Priority

    @Test("fetchTaskCountsByPriority returns correct counts per day per priority")
    func taskCountsByPriority() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        try repo.add(TodoItem(title: "H1", priority: .high, scheduledDate: today))
        try repo.add(TodoItem(title: "H2", priority: .high, scheduledDate: today))
        try repo.add(TodoItem(title: "M1", priority: .medium, scheduledDate: today))
        try repo.add(TodoItem(title: "L1", priority: .low, scheduledDate: tomorrow))

        let counts = try repo.fetchTaskCountsByPriority(for: [today, tomorrow])

        #expect(counts[today]?[.high] == 2)
        #expect(counts[today]?[.medium] == 1)
        #expect(counts[today]?[.low] == nil)
        #expect(counts[tomorrow]?[.low] == 1)
    }

    // MARK: - Done Count

    @Test("countDoneItems returns count for specific date")
    func countDoneItemsForDate() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let doneToday = TodoItem(title: "Done today", priority: .high, scheduledDate: today)
        doneToday.isDone = true
        doneToday.completedAt = Date()
        try repo.add(doneToday)

        let doneYesterday = TodoItem(title: "Done yesterday", priority: .high, scheduledDate: yesterday)
        doneYesterday.isDone = true
        doneYesterday.completedAt = yesterday
        try repo.add(doneYesterday)

        let todayCount = try repo.countDoneItems(for: today)
        let yesterdayCount = try repo.countDoneItems(for: yesterday)

        #expect(todayCount == 1)
        #expect(yesterdayCount == 1)
    }

    // MARK: - Repeating Item Lookup

    @Test("fetchRepeatingItem returns rule by ID")
    func fetchRepeatingItemByID() throws {
        let container = try makeContainer()
        let repo = makeRepo(container)

        let ctx = ModelContext(container)
        let rule = RepeatingItem(
            title: "Lookup test",
            frequency: .daily,
            scheduledTime: .now,
            defaultUrgency: .high
        )
        ctx.insert(rule)
        try ctx.save()

        let found = try repo.fetchRepeatingItem(by: rule.id)
        #expect(found?.title == "Lookup test")

        let notFound = try repo.fetchRepeatingItem(by: UUID())
        #expect(notFound == nil)
    }
}
