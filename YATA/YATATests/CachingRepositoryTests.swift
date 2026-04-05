import Testing
import SwiftData
import Foundation
@testable import YATA

@MainActor
@Suite("CachingRepository")
struct CachingRepositoryTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
            configurations: config
        )
    }

    private func makeRepo(_ container: ModelContainer) -> (CachingRepository, MutationLogger) {
        let local = LocalTodoRepository(modelContainer: container)
        let localRepeating = LocalRepeatingRepository(modelContainer: container)
        let loggerContext = ModelContext(container)
        loggerContext.autosaveEnabled = true
        let logger = MutationLogger(modelContext: loggerContext)
        let repo = CachingRepository(local: local, localRepeating: localRepeating, logger: logger)
        return (repo, logger)
    }

    // MARK: - TodoRepository Write Tests

    @Test("add delegates to local and logs a create mutation")
    func test_add_delegatesToLocalAndLogsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item = TodoItem(title: "Test item", priority: .high, scheduledDate: today)
        try repo.add(item)

        // Verify item exists in local store
        let items = try repo.fetchItems(for: today, priority: .high)
        #expect(items.count == 1)
        #expect(items[0].title == "Test item")

        // Verify mutation was logged
        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)
        #expect(mutations[0].entityType == "todoItem")
        #expect(mutations[0].entityID == item.id)
        #expect(mutations[0].mutationType == "create")
    }

    @Test("update delegates to local and logs an update mutation")
    func test_update_delegatesToLocalAndLogsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item = TodoItem(title: "Original", priority: .high, scheduledDate: today)
        try repo.add(item)

        item.title = "Updated"
        try repo.update(item)

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 2) // create + update
        let updateMutation = mutations.first { $0.mutationType == "update" }
        #expect(updateMutation != nil)
        #expect(updateMutation?.entityID == item.id)
    }

    @Test("delete delegates to local and logs a delete mutation")
    func test_delete_delegatesToLocalAndLogsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item = TodoItem(title: "Delete me", priority: .high, scheduledDate: today)
        let itemID = item.id
        try repo.add(item)

        try repo.delete(item)

        // Verify item is gone from local store
        let items = try repo.fetchItems(for: today, priority: .high)
        #expect(items.isEmpty)

        // Verify delete mutation logged with correct entityID
        let mutations = try logger.pendingMutations()
        let deleteMutation = mutations.first { $0.mutationType == "delete" }
        #expect(deleteMutation != nil)
        #expect(deleteMutation?.entityID == itemID)
    }

    @Test("fetchItems does not log any mutation")
    func test_fetchItems_doesNotLogMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        // Add an item directly to the local store so there's data to fetch
        let localRepo = LocalTodoRepository(modelContainer: container)
        let item = TodoItem(title: "Existing", priority: .medium, scheduledDate: today)
        try localRepo.add(item)

        _ = try repo.fetchItems(for: today, priority: .medium)

        let mutations = try logger.pendingMutations()
        #expect(mutations.isEmpty)
    }

    @Test("reorder logs a mutation with synthetic entityID")
    func test_reorder_logsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item1 = TodoItem(title: "A", priority: .high, sortOrder: 0, scheduledDate: today)
        let item2 = TodoItem(title: "B", priority: .high, sortOrder: 1, scheduledDate: today)
        try repo.add(item1)
        try repo.add(item2)

        try repo.reorder(ids: [item2.id, item1.id], in: .high)

        let mutations = try logger.pendingMutations()
        let reorderMutation = mutations.first { $0.mutationType == "reorder" }
        #expect(reorderMutation != nil)
        #expect(reorderMutation?.entityType == "todoItem")
    }

    @Test("move logs a mutation")
    func test_move_logsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)
        let today = Calendar.current.startOfDay(for: .now)

        let item = TodoItem(title: "Move me", priority: .low, scheduledDate: today)
        try repo.add(item)

        try repo.move(item, to: .high)

        let mutations = try logger.pendingMutations()
        let moveMutation = mutations.first { $0.mutationType == "move" }
        #expect(moveMutation != nil)
        #expect(moveMutation?.entityID == item.id)
    }

    // MARK: - RepeatingRepository Tests

    @Test("repeating add logs mutation with entityType repeatingItem")
    func test_repeatingAdd_logsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)

        let item = RepeatingItem(
            title: "Daily standup",
            frequency: .daily,
            scheduledTime: .now,
            defaultUrgency: .high
        )
        try repo.add(item)

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)
        #expect(mutations[0].entityType == "repeatingItem")
        #expect(mutations[0].entityID == item.id)
        #expect(mutations[0].mutationType == "create")
    }

    @Test("repeating delete logs mutation")
    func test_repeatingDelete_logsMutation() throws {
        let container = try makeContainer()
        let (repo, logger) = makeRepo(container)

        let item = RepeatingItem(
            title: "Delete this rule",
            frequency: .weekly,
            scheduledTime: .now,
            scheduledDayOfWeek: 2,
            defaultUrgency: .medium
        )
        let itemID = item.id
        try repo.add(item)

        try repo.delete(item)

        let mutations = try logger.pendingMutations()
        let deleteMutation = mutations.first { $0.mutationType == "delete" }
        #expect(deleteMutation != nil)
        #expect(deleteMutation?.entityID == itemID)
        #expect(deleteMutation?.entityType == "repeatingItem")
    }
}
