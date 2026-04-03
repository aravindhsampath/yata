import Foundation

enum Priority: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .high: "Do Today"
        case .medium: "This Week"
        case .low: "Wait"
        }
    }

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
