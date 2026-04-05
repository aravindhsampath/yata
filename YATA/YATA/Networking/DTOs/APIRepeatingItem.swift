import Foundation

struct APIRepeatingItem: Codable {
    let id: UUID
    let title: String
    let frequency: Int
    let scheduledTime: String
    let scheduledDayOfWeek: Int?
    let scheduledDayOfMonth: Int?
    let scheduledMonth: Int?
    let sortOrder: Int
    let defaultUrgency: Int
    let updatedAt: String?

    init(from repeatingItem: RepeatingItem) {
        self.id = repeatingItem.id
        self.title = repeatingItem.title
        self.frequency = repeatingItem.frequencyRawValue
        self.scheduledTime = DateFormatters.timeOnly.string(from: repeatingItem.scheduledTime)
        self.scheduledDayOfWeek = repeatingItem.scheduledDayOfWeek
        self.scheduledDayOfMonth = repeatingItem.scheduledDayOfMonth
        self.scheduledMonth = repeatingItem.scheduledMonth
        self.sortOrder = repeatingItem.sortOrder
        self.defaultUrgency = repeatingItem.defaultUrgencyRawValue
        self.updatedAt = repeatingItem.updatedAt.map { DateFormatters.iso8601DateTime.string(from: $0) }
    }

    func toRepeatingItem() -> RepeatingItem {
        let timeDate = DateFormatters.timeOnly.date(from: scheduledTime) ?? .now

        let item = RepeatingItem(
            title: title,
            frequency: RepeatFrequency(rawValue: frequency) ?? .daily,
            scheduledTime: timeDate,
            scheduledDayOfWeek: scheduledDayOfWeek,
            scheduledDayOfMonth: scheduledDayOfMonth,
            scheduledMonth: scheduledMonth,
            sortOrder: sortOrder,
            defaultUrgency: Priority(rawValue: defaultUrgency) ?? .high
        )
        item.id = id
        item.updatedAt = updatedAt.flatMap { DateFormatters.parseDateTime($0) }
        return item
    }
}
