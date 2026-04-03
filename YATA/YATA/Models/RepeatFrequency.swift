import Foundation

enum RepeatFrequency: Int, Codable, CaseIterable, Identifiable, Sendable {
    case daily = 0
    case everyWorkday = 1
    case weekly = 2
    case monthly = 3
    case yearly = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .everyWorkday: "Workdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}
