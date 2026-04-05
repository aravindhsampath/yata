import XCTest
import SwiftData
@testable import YATA

final class ModelMigrationTests: XCTestCase {

    private var container: ModelContainer!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([TodoItem.self, RepeatingItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    @MainActor
    func testTodoItemUpdatedAtDefaultsToNil() throws {
        let context = container.mainContext
        let item = TodoItem(title: "Test item", priority: .medium)
        XCTAssertNil(item.updatedAt)

        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].updatedAt)
    }

    @MainActor
    func testTodoItemUpdatedAtIsWritable() throws {
        let context = container.mainContext
        let item = TodoItem(title: "Test item", priority: .medium)
        context.insert(item)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        item.updatedAt = date
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].updatedAt!.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    @MainActor
    func testRepeatingItemUpdatedAtDefaultsToNil() throws {
        let context = container.mainContext
        let item = RepeatingItem(
            title: "Daily", frequency: .daily,
            scheduledTime: .now
        )
        XCTAssertNil(item.updatedAt)

        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RepeatingItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].updatedAt)
    }

    @MainActor
    func testRepeatingItemUpdatedAtIsWritable() throws {
        let context = container.mainContext
        let item = RepeatingItem(
            title: "Daily", frequency: .daily,
            scheduledTime: .now
        )
        context.insert(item)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        item.updatedAt = date
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RepeatingItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].updatedAt!.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }
}
