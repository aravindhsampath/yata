import Foundation

enum Weekday: Int, CaseIterable, Identifiable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var label: String {
        Calendar.current.weekdaySymbols[rawValue - 1]
    }

    var shortLabel: String {
        Calendar.current.shortWeekdaySymbols[rawValue - 1]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
