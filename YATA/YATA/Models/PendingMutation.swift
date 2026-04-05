import Foundation
import SwiftData

@Model
final class PendingMutation {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date.now
    var entityType: String = ""
    var entityID: UUID = UUID()
    var mutationType: String = ""
    var payload: Data = Data()
    var retryCount: Int = 0
    var lastError: String?

    init(
        entityType: String,
        entityID: UUID,
        mutationType: String,
        payload: Data
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.entityType = entityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.payload = payload
        self.retryCount = 0
        self.lastError = nil
    }
}
