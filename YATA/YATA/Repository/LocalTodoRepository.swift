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

    func fetchTodoItem(by id: UUID) throws -> TodoItem? {
        let predicate = #Predicate<TodoItem> { $0.id == id }
        var descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.scheduledDate < today
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let overdueItems = try modelContext.fetch(descriptor)

        for item in overdueItems {
            let daysOverdue = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.scheduledDate), to: today).day ?? 1
            item.rescheduleCount += max(daysOverdue, 1)
            item.scheduledDate = today
        }
        if !overdueItems.isEmpty {
            try modelContext.save()
        }
    }

    // MARK: - Occurrence Materialization

    func materializeRepeatingItems(for dateRange: ClosedRange<Date>) throws {
        let repeatingDescriptor = FetchDescriptor<RepeatingItem>()
        let rules = try modelContext.fetch(repeatingDescriptor)
        guard !rules.isEmpty else { return }

        let calendar = Calendar.current
        let rangeStart = dateRange.lowerBound
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: dateRange.upperBound)!

        // Single batch query: fetch all existing occurrences in range
        let existingPredicate = #Predicate<TodoItem> { item in
            item.sourceRepeatingID != nil
                && item.scheduledDate >= rangeStart
                && item.scheduledDate < rangeEnd
        }
        let existingOccurrences = try modelContext.fetch(
            FetchDescriptor<TodoItem>(predicate: existingPredicate)
        )

        // Build lookup: (ruleID, dateString) for O(1) membership check
        var existingKeys = Set<String>()
        for item in existingOccurrences {
            if let ruleID = item.sourceRepeatingID {
                let dayString = calendar.startOfDay(for: item.scheduledDate).timeIntervalSince1970
                existingKeys.insert("\(ruleID)-\(dayString)")
            }
        }

        var didInsert = false
        for rule in rules {
            let firingDates = computeFiringDates(for: rule, in: dateRange, calendar: calendar)

            for firingDate in firingDates {
                let dayStart = calendar.startOfDay(for: firingDate)
                let key = "\(rule.id)-\(dayStart.timeIntervalSince1970)"
                guard !existingKeys.contains(key) else { continue }

                let occurrence = TodoItem(
                    title: rule.title,
                    priority: rule.defaultUrgency,
                    sortOrder: 999,
                    scheduledDate: dayStart,
                    sourceRepeatingID: rule.id
                )
                occurrence.sourceRepeatingRuleName = rule.title
                modelContext.insert(occurrence)
                existingKeys.insert(key)
                didInsert = true
            }
        }
        if didInsert {
            try modelContext.save()
        }
    }

    // MARK: - Orphan Cleanup

    func deleteUndoneOccurrences(for repeatingID: UUID) throws {
        let predicate = #Predicate<TodoItem> { item in
            item.sourceRepeatingID == repeatingID && item.isDone == false
        }
        let descriptor = FetchDescriptor<TodoItem>(predicate: predicate)
        let orphans = try modelContext.fetch(descriptor)
        for orphan in orphans {
            modelContext.delete(orphan)
        }
        if !orphans.isEmpty {
            try modelContext.save()
        }
    }

    // MARK: - Reschedule

    func reschedule(_ item: TodoItem, to date: Date, resetCount: Bool = true) throws {
        let newDate = Calendar.current.startOfDay(for: date)
        let oldDate = Calendar.current.startOfDay(for: item.scheduledDate)
        if newDate != oldDate {
            item.scheduledDate = newDate
            if resetCount {
                item.rescheduleCount = 0
            } else {
                item.rescheduleCount += 1
            }
        }
        try modelContext.save()
    }

    // MARK: - Week Task Counts

    func fetchTaskCountsByPriority(for dates: [Date]) throws -> [Date: [Priority: Int]] {
        guard let earliest = dates.min(), let latest = dates.max() else { return [:] }
        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: earliest)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latest))!
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == false && item.scheduledDate >= rangeStart && item.scheduledDate < rangeEnd
        }
        let items = try modelContext.fetch(FetchDescriptor<TodoItem>(predicate: predicate))
        var result: [Date: [Priority: Int]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.scheduledDate)
            result[day, default: [:]][item.priority, default: 0] += 1
        }
        return result
    }

    // MARK: - Done Count

    func countDoneItems(for date: Date) throws -> Int {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let predicate = #Predicate<TodoItem> { item in
            item.isDone == true
        }
        let items = try modelContext.fetch(FetchDescriptor<TodoItem>(predicate: predicate))
        return items.filter { item in
            guard let completedAt = item.completedAt else { return false }
            return completedAt >= dayStart && completedAt < dayEnd
        }.count
    }

    // MARK: - Repeating Item Lookup

    func fetchRepeatingItem(by id: UUID) throws -> RepeatingItem? {
        let predicate = #Predicate<RepeatingItem> { $0.id == id }
        var descriptor = FetchDescriptor<RepeatingItem>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
