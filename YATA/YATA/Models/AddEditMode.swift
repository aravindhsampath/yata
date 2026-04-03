import Foundation

enum AddEditMode: Identifiable {
    case add
    case edit(TodoItem)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let item): item.id.uuidString
        }
    }
}
