import XCTest
@testable import YATA

/// Verifies the recovery path added in P1.7. The bug we used to ship
/// was `try! ModelContainer(...)` in `YATAApp.init()` — corrupt store
/// crashes the app silently on cold launch, no recovery, no clue.
///
/// `DataStoreLoader` makes the failure observable and provides a
/// `reset()` path the UI can drive. These tests prove all three:
///
/// 1. A fresh URL loads cleanly.
/// 2. A corrupt file at the URL causes `load()` to throw.
/// 3. After `resetAndLoad()`, the corrupt file is gone and a fresh
///    container is returned.
final class DataStoreLoaderTests: XCTestCase {

    /// Each test gets its own temp directory so concurrent test
    /// runs (and CI parallelism) don't share state.
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        let nanos = Int(Date().timeIntervalSince1970 * 1_000_000_000)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yata-loader-test-\(nanos)-\(getpid())")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        storeURL = tempDir.appendingPathComponent("yata.store")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Tests

    func test_load_onFreshURL_succeeds() throws {
        let loader = DataStoreLoader(storeURL: storeURL)
        // Should not throw; SwiftData creates the file.
        let container = try loader.load()
        XCTAssertNotNil(container, "fresh URL should produce a working container")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "store file should exist on disk after a successful load"
        )
    }

    func test_load_onCorruptStore_throws() throws {
        // Plant a deliberately-malformed file at the store URL —
        // SwiftData should reject it at open time.
        try Data("not a sqlite database".utf8)
            .write(to: storeURL)

        let loader = DataStoreLoader(storeURL: storeURL)
        XCTAssertThrowsError(try loader.load(), "corrupt file must surface as a thrown error, not a crash") { error in
            // We don't pin the exact error type — SwiftData's
            // surface changes between OS versions. We just verify
            // *something* threw, which is what makes the recovery
            // UI possible.
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "thrown error should have a description we can show the user"
            )
        }
    }

    func test_resetAndLoad_afterCorruption_recovers() throws {
        // Start with a corrupt store.
        try Data("torn snapshot".utf8).write(to: storeURL)

        let loader = DataStoreLoader(storeURL: storeURL)
        XCTAssertThrowsError(try loader.load(), "preconditions: corrupt store must fail to load")

        // Recovery path: nuke + retry.
        let container = try loader.resetAndLoad()
        XCTAssertNotNil(container, "resetAndLoad should produce a working container")
    }

    func test_reset_isIdempotent_whenStoreMissing() throws {
        // No file on disk yet. reset() must not throw.
        let loader = DataStoreLoader(storeURL: storeURL)
        XCTAssertNoThrow(try loader.reset(), "reset on a missing store should be a no-op")
    }

    func test_reset_removesWALAndSHMSidecars() throws {
        // SwiftData runs in WAL mode; a real reset has to take all
        // three files or the next open inherits the old WAL. Plant
        // synthetic sidecars and verify all three are cleared.
        try Data("main".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: storeURL.appendingPathExtension("wal"))
        try Data("shm".utf8).write(to: storeURL.appendingPathExtension("shm"))

        let loader = DataStoreLoader(storeURL: storeURL)
        try loader.reset()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: storeURL.path), "main file must be deleted")
        XCTAssertFalse(
            fm.fileExists(atPath: storeURL.appendingPathExtension("wal").path),
            "wal sidecar must be deleted"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: storeURL.appendingPathExtension("shm").path),
            "shm sidecar must be deleted"
        )
    }

    func test_defaultStoreURL_pointsIntoApplicationSupport() {
        // Sanity: we don't accidentally wipe Documents/ or
        // somewhere else user-visible.
        let url = DataStoreLoader.defaultStoreURL()
        XCTAssertTrue(
            url.path.contains("Application Support") || url.path.contains("Library"),
            "default store should live under Library/Application Support, got \(url.path)"
        )
        XCTAssertEqual(url.lastPathComponent, "default.store")
    }
}
