import Foundation
import SwiftData

@MainActor
final class MutationLogger {
    private let modelContext: ModelContext

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func log(entityType: String, entityID: UUID, mutationType: String, payload: Encodable) throws {
        let data = try Self.encoder.encode(AnyEncodable(payload))
        let mutation = PendingMutation(
            entityType: entityType,
            entityID: entityID,
            mutationType: mutationType,
            payload: data
        )
        modelContext.insert(mutation)
        try modelContext.save()
    }

    func pendingMutations() throws -> [PendingMutation] {
        var descriptor = FetchDescriptor<PendingMutation>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 10_000
        return try modelContext.fetch(descriptor)
    }

    func deleteMutation(_ mutation: PendingMutation) throws {
        modelContext.delete(mutation)
        try modelContext.save()
    }

    func compact() throws {
        let mutations = try pendingMutations()
        guard !mutations.isEmpty else { return }

        // Group by (entityType, entityID)
        var groups: [String: [PendingMutation]] = [:]
        for mutation in mutations {
            let key = "\(mutation.entityType)|\(mutation.entityID)"
            groups[key, default: []].append(mutation)
        }

        for (_, group) in groups {
            guard group.count > 1 else { continue }

            let types = Set(group.map(\.mutationType))

            // Rule 1: Create + Delete of same entity -> remove both
            if types.contains("create") && types.contains("delete") {
                for m in group {
                    modelContext.delete(m)
                }
                continue
            }

            // Rule 3: Create + one or more updates -> merge into single create
            if types.contains("create") {
                let creates = group.filter { $0.mutationType == "create" }
                let updates = group.filter { $0.mutationType == "update" }

                if let createMutation = creates.first, !updates.isEmpty {
                    // Find latest update
                    let latestUpdate = updates.max(by: { $0.createdAt < $1.createdAt })!

                    // Merge: decode create payload, overlay update fields
                    if let createDict = try? JSONSerialization.jsonObject(with: createMutation.payload) as? [String: Any],
                       let updateDict = try? JSONSerialization.jsonObject(with: latestUpdate.payload) as? [String: Any] {
                        var merged = createDict
                        for (key, value) in updateDict {
                            merged[key] = value
                        }
                        let mergedData = try JSONSerialization.data(withJSONObject: merged)
                        createMutation.payload = mergedData
                    }

                    // Delete all updates
                    for update in updates {
                        modelContext.delete(update)
                    }
                }
                continue
            }

            // Rule 2: Multiple updates to same entity -> keep only latest
            if types == Set(["update"]) {
                let sorted = group.sorted { $0.createdAt < $1.createdAt }
                // Delete all but the last
                for m in sorted.dropLast() {
                    modelContext.delete(m)
                }
                continue
            }
        }

        try modelContext.save()
    }
}

// MARK: - Type-erased Encodable wrapper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: Encodable) {
        _encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
