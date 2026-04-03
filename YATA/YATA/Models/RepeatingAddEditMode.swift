import Foundation

enum RepeatingAddEditMode: Identifiable {
    case add
    case edit(RepeatingItem)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let item): item.id.uuidString
        }
    }
}
