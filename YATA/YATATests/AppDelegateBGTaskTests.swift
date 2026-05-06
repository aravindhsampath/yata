import XCTest
@testable import YATA

/// Verifies the BGTask cast safety added in P1.6.
///
/// The bug we're guarding against: the BGTaskScheduler closure used
/// to force-cast `task as! BGAppRefreshTask`, which crashes the app
/// in the background if iOS ever delivers a sibling subclass for
/// our identifier. The `dispatch(task:)` method now downcasts
/// safely and signals incompletion instead.
///
/// `BGTask` is `final` and has no public initializer, so we can't
/// construct one for tests. The `DispatchableTask` protocol carved
/// out of it is the seam — a stub that conforms to the protocol
/// flows through the same code path without needing a real
/// `BGAppRefreshTask`.
final class AppDelegateBGTaskTests: XCTestCase {

    /// Records every call to `setTaskCompleted(success:)` so the
    /// test can assert what the dispatch layer decided.
    @MainActor
    final class StubTask: DispatchableTask {
        var completedCalls: [Bool] = []
        func setTaskCompleted(success: Bool) {
            completedCalls.append(success)
        }
    }

    @MainActor
    func test_dispatch_withWrongTaskSubclass_marksIncompleteAndDoesNotCrash() {
        let delegate = AppDelegate()
        let stub = StubTask()

        // Stub is NOT a BGAppRefreshTask — the downcast must fail
        // and `setTaskCompleted(success: false)` must fire. With
        // the old force-cast this line would crash the test (and
        // the app, in production).
        delegate.dispatch(task: stub)

        XCTAssertEqual(
            stub.completedCalls,
            [false],
            "wrong subclass: expected exactly one setTaskCompleted(false), got \(stub.completedCalls)"
        )
    }

    /// Sanity: a freshly-constructed AppDelegate doesn't panic when
    /// asked to dispatch (it doesn't need a ModelContainer or
    /// RepositoryProvider for the wrong-subclass path).
    @MainActor
    func test_dispatch_doesNotRequireModelContainer() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.modelContainer, "preconditions: pristine state")
        let stub = StubTask()
        delegate.dispatch(task: stub)
        XCTAssertEqual(stub.completedCalls, [false])
    }
}
