import Testing
import SwiftData
import Foundation
@testable import YATA

@MainActor
@Suite("MutationLogger")
struct MutationLoggerTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
            configurations: config
        )
    }

    private func makeLogger(_ container: ModelContainer) -> MutationLogger {
        MutationLogger(modelContext: ModelContext(container))
    }

    // MARK: - Basic Operations

    @Test("log creates a PendingMutation entry")
    func test_log_createsMutation() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)
        let entityID = UUID()

        try logger.log(
            entityType: "todoItem",
            entityID: entityID,
            mutationType: "create",
            payload: TestPayload(name: "test")
        )

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)
        #expect(mutations[0].entityType == "todoItem")
        #expect(mutations[0].entityID == entityID)
        #expect(mutations[0].mutationType == "create")
        #expect(mutations[0].retryCount == 0)
        #expect(mutations[0].lastError == nil)
    }

    @Test("pendingMutations returns entries ordered by createdAt ascending")
    func test_pendingMutations_orderedByCreatedAt() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)

        let id1 = UUID(), id2 = UUID(), id3 = UUID()

        // Insert with different createdAt values by manipulating the model directly
        let ctx = ModelContext(container)
        let m1 = PendingMutation(entityType: "todoItem", entityID: id1, mutationType: "create", payload: "{}".data(using: .utf8)!)
        m1.createdAt = Date(timeIntervalSince1970: 1000)
        let m2 = PendingMutation(entityType: "todoItem", entityID: id2, mutationType: "create", payload: "{}".data(using: .utf8)!)
        m2.createdAt = Date(timeIntervalSince1970: 3000)
        let m3 = PendingMutation(entityType: "todoItem", entityID: id3, mutationType: "create", payload: "{}".data(using: .utf8)!)
        m3.createdAt = Date(timeIntervalSince1970: 2000)

        ctx.insert(m2) // insert out of order
        ctx.insert(m3)
        ctx.insert(m1)
        try ctx.save()

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 3)
        #expect(mutations[0].entityID == id1) // earliest
        #expect(mutations[1].entityID == id3) // middle
        #expect(mutations[2].entityID == id2) // latest
    }

    @Test("deleteMutation removes entry from queue")
    func test_deleteMutation_removesFromQueue() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)

        try logger.log(entityType: "todoItem", entityID: UUID(), mutationType: "create", payload: TestPayload(name: "a"))
        try logger.log(entityType: "todoItem", entityID: UUID(), mutationType: "create", payload: TestPayload(name: "b"))

        var mutations = try logger.pendingMutations()
        #expect(mutations.count == 2)

        try logger.deleteMutation(mutations[0])

        mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)
    }

    // MARK: - Compaction

    @Test("compact: create + delete of same entity removes both")
    func test_compact_createThenDelete_removesBoth() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)
        let entityID = UUID()

        try logger.log(entityType: "todoItem", entityID: entityID, mutationType: "create", payload: TestPayload(name: "new"))
        try logger.log(entityType: "todoItem", entityID: entityID, mutationType: "delete", payload: TestPayload(name: ""))

        try logger.compact()

        let mutations = try logger.pendingMutations()
        #expect(mutations.isEmpty)
    }

    @Test("compact: multiple updates to same entity keeps only latest")
    func test_compact_multipleUpdates_keepsLatest() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let logger = MutationLogger(modelContext: ctx)
        let entityID = UUID()

        let m1 = PendingMutation(entityType: "todoItem", entityID: entityID, mutationType: "update", payload: try encode(TestPayload(name: "first")))
        m1.createdAt = Date(timeIntervalSince1970: 1000)
        let m2 = PendingMutation(entityType: "todoItem", entityID: entityID, mutationType: "update", payload: try encode(TestPayload(name: "second")))
        m2.createdAt = Date(timeIntervalSince1970: 2000)
        let m3 = PendingMutation(entityType: "todoItem", entityID: entityID, mutationType: "update", payload: try encode(TestPayload(name: "third")))
        m3.createdAt = Date(timeIntervalSince1970: 3000)

        ctx.insert(m1)
        ctx.insert(m2)
        ctx.insert(m3)
        try ctx.save()

        try logger.compact()

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)

        // Verify it kept the latest
        let decoded = try JSONSerialization.jsonObject(with: mutations[0].payload) as? [String: Any]
        #expect(decoded?["name"] as? String == "third")
    }

    @Test("compact: create + updates merges into single create")
    func test_compact_createThenUpdates_mergesIntoCreate() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let logger = MutationLogger(modelContext: ctx)
        let entityID = UUID()

        let createPayload: [String: Any] = ["name": "original", "priority": 1]
        let update1Payload: [String: Any] = ["name": "updated1"]
        let update2Payload: [String: Any] = ["name": "final", "priority": 2]

        let m1 = PendingMutation(
            entityType: "todoItem", entityID: entityID, mutationType: "create",
            payload: try JSONSerialization.data(withJSONObject: createPayload)
        )
        m1.createdAt = Date(timeIntervalSince1970: 1000)
        let m2 = PendingMutation(
            entityType: "todoItem", entityID: entityID, mutationType: "update",
            payload: try JSONSerialization.data(withJSONObject: update1Payload)
        )
        m2.createdAt = Date(timeIntervalSince1970: 2000)
        let m3 = PendingMutation(
            entityType: "todoItem", entityID: entityID, mutationType: "update",
            payload: try JSONSerialization.data(withJSONObject: update2Payload)
        )
        m3.createdAt = Date(timeIntervalSince1970: 3000)

        ctx.insert(m1)
        ctx.insert(m2)
        ctx.insert(m3)
        try ctx.save()

        try logger.compact()

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 1)
        #expect(mutations[0].mutationType == "create")

        let merged = try JSONSerialization.jsonObject(with: mutations[0].payload) as? [String: Any]
        #expect(merged?["name"] as? String == "final")
        #expect(merged?["priority"] as? Int == 2)
    }

    @Test("compact preserves unrelated mutations")
    func test_compact_preservesUnrelatedMutations() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)

        let id1 = UUID(), id2 = UUID()
        try logger.log(entityType: "todoItem", entityID: id1, mutationType: "create", payload: TestPayload(name: "a"))
        try logger.log(entityType: "todoItem", entityID: id2, mutationType: "update", payload: TestPayload(name: "b"))

        try logger.compact()

        let mutations = try logger.pendingMutations()
        #expect(mutations.count == 2)
    }

    @Test("compact treats different entityTypes separately even with same entityID")
    func test_compact_mixedEntityTypes_treatedSeparately() throws {
        let container = try makeContainer()
        let logger = makeLogger(container)
        let sharedID = UUID()

        try logger.log(entityType: "todoItem", entityID: sharedID, mutationType: "create", payload: TestPayload(name: "todo"))
        try logger.log(entityType: "repeatingItem", entityID: sharedID, mutationType: "create", payload: TestPayload(name: "repeating"))
        try logger.log(entityType: "todoItem", entityID: sharedID, mutationType: "delete", payload: TestPayload(name: ""))

        try logger.compact()

        let mutations = try logger.pendingMutations()
        // todoItem create+delete -> removed; repeatingItem create -> preserved
        #expect(mutations.count == 1)
        #expect(mutations[0].entityType == "repeatingItem")
    }

    // MARK: - Helpers

    private func encode(_ value: Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(AnyTestEncodable(value))
    }
}

// MARK: - Test helpers

private struct TestPayload: Encodable {
    let name: String
}

private struct AnyTestEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: Encodable) {
        _encode = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
