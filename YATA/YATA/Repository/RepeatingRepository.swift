import Foundation

@MainActor
protocol RepeatingRepository {
    func fetchItems() async throws -> [RepeatingItem]
    func add(_ item: RepeatingItem) async throws
    func update(_ item: RepeatingItem) async throws
    func delete(_ item: RepeatingItem) async throws
}
