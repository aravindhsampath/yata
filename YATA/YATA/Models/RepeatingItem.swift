import Foundation
import SwiftData

@Model
final class RepeatingItem {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var frequencyRawValue: Int = 0
    var scheduledTime: Date = Date.now
    var scheduledDayOfWeek: Int?   // 1=Sunday ... 7=Saturday (Calendar weekday)
    var scheduledDayOfMonth: Int?  // 1-28
    var scheduledMonth: Int?       // 1-12
    var sortOrder: Int = 0
    var createdAt: Date = Date.now
    var updatedAt: Date?
    var defaultUrgencyRawValue: Int = 2  // Priority.high (green / "Do Today")

    var frequency: RepeatFrequency {
        get { RepeatFrequency(rawValue: frequencyRawValue) ?? .daily }
        set { frequencyRawValue = newValue.rawValue }
    }

    /// Human-readable schedule summary for display on the pill
    var scheduleSummary: String {
        let time = scheduledTime.formatted(.dateTime.hour().minute())
        switch frequency {
        case .daily, .everyWorkday:
            return time
        case .weekly:
            let day = scheduledDayOfWeek.flatMap { Weekday(rawValue: $0)?.shortLabel } ?? "?"
            return "\(day) \(time)"
        case .monthly:
            if let d = scheduledDayOfMonth {
                return "\(ordinal(d)) \(time)"
            }
            return time
        case .yearly:
            let month = scheduledMonth.flatMap { Calendar.current.shortMonthSymbols[safe: $0 - 1] } ?? "?"
            let day = scheduledDayOfMonth.map { "\($0)" } ?? "?"
            return "\(month) \(day) \(time)"
        }
    }

    var nextOccurrenceLabel: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // Search up to 366 days ahead
        for dayOffset in 0..<366 {
            guard let candidate = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let shouldFire: Bool
            switch frequency {
            case .daily:
                shouldFire = true
            case .everyWorkday:
                let weekday = calendar.component(.weekday, from: candidate)
                shouldFire = (2...6).contains(weekday)
            case .weekly:
                let weekday = calendar.component(.weekday, from: candidate)
                shouldFire = weekday == (scheduledDayOfWeek ?? 2)
            case .monthly:
                let day = calendar.component(.day, from: candidate)
                shouldFire = day == (scheduledDayOfMonth ?? 1)
            case .yearly:
                let month = calendar.component(.month, from: candidate)
                let day = calendar.component(.day, from: candidate)
                shouldFire = month == (scheduledMonth ?? 1) && day == (scheduledDayOfMonth ?? 1)
            }
            if shouldFire {
                if calendar.isDateInToday(candidate) { return "Next: Today" }
                if calendar.isDateInTomorrow(candidate) { return "Next: Tomorrow" }
                return "Next: \(candidate.formatted(.dateTime.weekday(.wide)))"
            }
        }
        return ""
    }

    var defaultUrgency: Priority {
        get { Priority(rawValue: defaultUrgencyRawValue) ?? .high }
        set { defaultUrgencyRawValue = newValue.rawValue }
    }

    init(
        title: String,
        frequency: RepeatFrequency,
        scheduledTime: Date,
        scheduledDayOfWeek: Int? = nil,
        scheduledDayOfMonth: Int? = nil,
        scheduledMonth: Int? = nil,
        sortOrder: Int = 0,
        defaultUrgency: Priority = .high
    ) {
        self.id = UUID()
        self.title = title
        self.frequencyRawValue = frequency.rawValue
        self.scheduledTime = scheduledTime
        self.scheduledDayOfWeek = scheduledDayOfWeek
        self.scheduledDayOfMonth = scheduledDayOfMonth
        self.scheduledMonth = scheduledMonth
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.defaultUrgencyRawValue = defaultUrgency.rawValue
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        let ones = n % 10, tens = n % 100
        if tens >= 11 && tens <= 13 { suffix = "th" }
        else if ones == 1 { suffix = "st" }
        else if ones == 2 { suffix = "nd" }
        else if ones == 3 { suffix = "rd" }
        else { suffix = "th" }
        return "\(n)\(suffix)"
    }
}
