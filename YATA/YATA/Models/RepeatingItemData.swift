import Foundation

struct RepeatingItemData {
    let title: String
    let frequency: RepeatFrequency
    let scheduledTime: Date
    let dayOfWeek: Int?
    let dayOfMonth: Int?
    let month: Int?
    let defaultUrgency: Priority
}
