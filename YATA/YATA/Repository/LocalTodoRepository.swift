import Foundation
import SwiftData

@MainActor
final class LocalTodoRepository: TodoRepository {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
        self.modelContext.autosaveEnabled = true
    }

    func fetchItems(for date: Date, priority: Priority) throws -> [TodoItem] {
        let rawValue = priority.rawValue
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false
                && item.priorityRawValue == rawValue
                && item.scheduledDate >= dayStart
                && item.scheduledDate < dayEnd
        }
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor)
    }

    func fetchDoneItems(limit: Int) throws -> [TodoItem] {
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == true
        }
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    func add(_ item: TodoItem) throws {
        modelContext.insert(item)
        try modelContext.save()
    }

    func update(_ item: TodoItem) throws {
        try modelContext.save()
    }

    func delete(_ item: TodoItem) throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    func reorder(ids: [UUID], in priority: Priority) throws {
        let rawValue = priority.rawValue
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.priorityRawValue == rawValue
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let items = try modelContext.fetch(descriptor)

        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            lookup[id]?.sortOrder = index
        }
        try modelContext.save()
    }

    func move(_ item: TodoItem, to priority: Priority) throws {
        item.priority = priority
        let rawValue = priority.rawValue
        let predicate = #Predicate<TodoItem> { existing in
            existing.isDone == false && existing.priorityRawValue == rawValue
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let count = try modelContext.fetchCount(descriptor)
        item.sortOrder = count
        try modelContext.save()
    }

    // MARK: - Rollover

    func rolloverOverdueItems(to date: Date) throws {
        let today = Calendar.current.startOfDay(for: date)
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.scheduledDate < today
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let overdueItems = try modelContext.fetch(descriptor)

        for item in overdueItems {
            item.scheduledDate = today
            item.rescheduleCount += 1
        }
        if !overdueItems.isEmpty {
            try modelContext.save()
        }
    }

    // MARK: - Occurrence Materialization

    func materializeRepeatingItems(for dateRange: ClosedRange<Date>, using container: Any) throws {
        guard let modelContainer = container as? ModelContainer else { return }
        let repeatingContext = ModelContext(modelContainer)
        let repeatingDescriptor = FetchDescriptor<RepeatingItem>()
        let rules = try repeatingContext.fetch(repeatingDescriptor)

        let calendar = Calendar.current

        for rule in rules {
            let firingDates = computeFiringDates(for: rule, in: dateRange, calendar: calendar)

            for firingDate in firingDates {
                let dayStart = calendar.startOfDay(for: firingDate)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let ruleID = rule.id

                let predicate = #Predicate<TodoItem> { item in
                    item.sourceRepeatingID == ruleID
                        && item.scheduledDate >= dayStart
                        && item.scheduledDate < dayEnd
                }
                let existing = try modelContext.fetchCount(FetchDescriptor<TodoItem>(predicate: predicate))
                guard existing == 0 else { continue }

                let occurrence = TodoItem(
                    title: rule.title,
                    priority: rule.defaultUrgency,
                    sortOrder: 999,
                    scheduledDate: dayStart,
                    sourceRepeatingID: rule.id
                )
                modelContext.insert(occurrence)
            }
        }
        try modelContext.save()
    }

    // MARK: - Reschedule

    func reschedule(_ item: TodoItem, to date: Date) throws {
        item.scheduledDate = Calendar.current.startOfDay(for: date)
        item.rescheduleCount = 0
        try modelContext.save()
    }

    // MARK: - Firing Date Computation

    private func computeFiringDates(
        for rule: RepeatingItem,
        in range: ClosedRange<Date>,
        calendar: Calendar
    ) -> [Date] {
        var dates: [Date] = []
        var current = range.lowerBound

        while current <= range.upperBound {
            let shouldFire: Bool
            switch rule.frequency {
            case .daily:
                shouldFire = true
            case .everyWorkday:
                let weekday = calendar.component(.weekday, from: current)
                shouldFire = (2...6).contains(weekday) // Mon-Fri
            case .weekly:
                let weekday = calendar.component(.weekday, from: current)
                shouldFire = weekday == (rule.scheduledDayOfWeek ?? 2)
            case .monthly:
                let day = calendar.component(.day, from: current)
                shouldFire = day == (rule.scheduledDayOfMonth ?? 1)
            case .yearly:
                let month = calendar.component(.month, from: current)
                let day = calendar.component(.day, from: current)
                shouldFire = month == (rule.scheduledMonth ?? 1)
                    && day == (rule.scheduledDayOfMonth ?? 1)
            }
            if shouldFire { dates.append(current) }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return dates
    }
}
