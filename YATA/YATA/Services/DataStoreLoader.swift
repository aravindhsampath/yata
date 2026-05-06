import Foundation
import SwiftData

/// Loads the SwiftData store with structured error handling and a
/// nuke-and-retry recovery path.
///
/// Why this exists: `try! ModelContainer(...)` in `YATAApp.init()`
/// hard-crashes the app on cold launch if the on-disk store is
/// corrupt, the schema migration fails, or the disk is full. The
/// user sees "YATA quit unexpectedly" with no recovery — they have
/// to delete + reinstall to get back in. SwiftData migrations
/// genuinely fail in the wild (Apple radar history is long), so we
/// want a graceful path: surface the error, offer a Reset button.
///
/// The `storeURL` is injectable so tests can drive corrupt-file
/// scenarios without polluting the user's Application Support.
struct DataStoreLoader {

    /// On-disk path to the SwiftData store. Defaults to the
    /// production location (Application Support / default.store).
    let storeURL: URL

    init(storeURL: URL = Self.defaultStoreURL()) {
        self.storeURL = storeURL
    }

    /// Open the store. Returns the live `ModelContainer` or throws
    /// the underlying SwiftData error. Callers should classify and
    /// surface the error rather than crashing.
    func load() throws -> ModelContainer {
        let configuration = ModelConfiguration(url: storeURL)
        return try ModelContainer(
            for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
            configurations: configuration
        )
    }

    /// Delete the store and its WAL/SHM sidecars from disk.
    /// Idempotent: missing files are silently skipped. Used by the
    /// "Reset Local Data" recovery button. The next `load()` will
    /// produce a fresh empty store.
    func reset() throws {
        let fm = FileManager.default
        for url in [storeURL, walURL, shmURL] {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }

    /// Convenience: `reset()` then `load()`. The recovery button
    /// drives this in one step so the UI doesn't have to plumb two
    /// fallible calls.
    func resetAndLoad() throws -> ModelContainer {
        try reset()
        return try load()
    }

    // MARK: - Internal helpers

    private var walURL: URL {
        storeURL.appendingPathExtension("wal")
    }

    private var shmURL: URL {
        storeURL.appendingPathExtension("shm")
    }

    /// SwiftData's default store filename is `default.store` under
    /// Application Support. We pin the same path explicitly so
    /// existing user data continues to load after this refactor.
    /// (If we'd switched to a different filename, every existing
    /// install would appear empty.)
    static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        // Application Support is the right place per Apple's
        // "File System Programming Guide" — User-visible Documents
        // is for files the user authored explicitly.
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return dir.appendingPathComponent("default.store")
    }
}
