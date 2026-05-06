import SwiftData
import XCTest
@testable import YATA

/// Verifies the cold-launch race-window fix added in P1.8.
///
/// Pre-fix, notification-action handlers in AppDelegate read
/// `modelContainer` directly. SwiftUI populates that property from
/// `YATAApp.body`'s `.onAppear`, which fires AFTER iOS has already
/// delivered any pending `userNotificationCenter(_:didReceive:)`
/// from a cold-launch-from-notification tap. The handler bailed
/// silently and the user's tap was lost.
///
/// `awaitContainer(timeoutSeconds:)` closes the gap: handlers
/// suspend until the container is set or the timeout fires.
final class AppDelegateAwaitContainerTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        // Fresh in-memory container for each test.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
            configurations: config
        )
    }

    @MainActor
    func test_awaitContainer_returnsImmediately_whenAlreadyWired() async {
        let delegate = AppDelegate()
        delegate.modelContainer = container
        delegate.repositoryProvider = RepositoryProvider(container: container)

        let result = await delegate.awaitContainer(timeoutSeconds: 1)
        XCTAssertNotNil(result, "should resolve immediately when already wired")
    }

    @MainActor
    func test_awaitContainer_resolves_whenWiringHappensAfterCall() async {
        let delegate = AppDelegate()
        // Don't wire yet — simulate the cold-launch race.

        // Kick off the await in a Task.
        let waiter = Task {
            await delegate.awaitContainer(timeoutSeconds: 2)
        }

        // Wire the delegate after a short delay (mimics the
        // `.onAppear` lag).
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            await MainActor.run {
                delegate.modelContainer = self.container
                delegate.repositoryProvider = RepositoryProvider(container: self.container)
            }
        }

        let result = await waiter.value
        XCTAssertNotNil(
            result,
            "awaitContainer should resolve once modelContainer + repositoryProvider are wired"
        )
    }

    @MainActor
    func test_awaitContainer_returnsNil_onTimeout() async {
        let delegate = AppDelegate()
        // Never wire — let the timeout fire.

        let started = Date()
        let result = await delegate.awaitContainer(timeoutSeconds: 0.2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result, "expected nil after timeout, got non-nil")
        XCTAssertGreaterThanOrEqual(
            elapsed,
            0.18,
            "awaitContainer must actually wait close to the timeout, not bail instantly"
        )
        XCTAssertLessThan(
            elapsed,
            1.0,
            "awaitContainer must respect the timeout, not hang forever"
        )
    }

    @MainActor
    func test_awaitContainer_returnsNil_whenOnlyContainerWired() async {
        // Both `modelContainer` AND `repositoryProvider` must be
        // present — half-wiring shouldn't return early. This catches
        // a future refactor that forgets the provider check.
        let delegate = AppDelegate()
        delegate.modelContainer = container
        // repositoryProvider intentionally left nil.

        let result = await delegate.awaitContainer(timeoutSeconds: 0.15)
        XCTAssertNil(result, "should not resolve until repositoryProvider is also set")
    }
}
