import Foundation
import SwiftData

@Model
final class RepeatingItem {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var frequencyRawValue: Int = 0
    var scheduledTime: Date = Date.now
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    var frequency: RepeatFrequency {
        get { RepeatFrequency(rawValue: frequencyRawValue) ?? .daily }
        set { frequencyRawValue = newValue.rawValue }
    }

    init(
        title: String,
        frequency: RepeatFrequency,
        scheduledTime: Date,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.title = title
        self.frequencyRawValue = frequency.rawValue
        self.scheduledTime = scheduledTime
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
