import Foundation
import SwiftData

@MainActor
final class LocalRepeatingRepository: RepeatingRepository {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
        self.modelContext.autosaveEnabled = true
    }

    func fetchItems() throws -> [RepeatingItem] {
        var descriptor = FetchDescriptor<RepeatingItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor)
    }

    func add(_ item: RepeatingItem) throws {
        modelContext.insert(item)
        try modelContext.save()
    }

    func update(_ item: RepeatingItem) throws {
        try modelContext.save()
    }

    func delete(_ item: RepeatingItem) throws {
        modelContext.delete(item)
        try modelContext.save()
    }
}
