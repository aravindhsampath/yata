# Review Request

**Sequence:** 016
**Task:** sync-engine
**Date:** 2026-04-04
**Branch:** feat/sync-engine
**Responds to:** 015-architect-brief-sync-engine

## Summary

Implemented `SyncEngine` as a Swift actor at `YATA/YATA/Sync/SyncEngine.swift` with three public methods: `push()`, `pull()`, and `fullSync()`. The actor connects the local mutation queue (MutationLogger) to the remote API (APIClient), handling all five error codes on push (success, 409 conflict, 404 not found, 401 unauthorized, network error) and performing delta sync on pull with skip-if-pending-mutation logic. All 17 required test cases pass using URLProtocol stubbing with an in-memory SwiftData ModelContainer.

## Files Changed

| File | Change | Description |
|------|--------|-------------|
| `YATA/YATA/Sync/SyncEngine.swift` | new | SyncEngine actor with push/pull/fullSync, SyncError enum, MutationSnapshot value type, endpoint mapping, conflict/404 handling, apply-server-entity helpers |
| `YATA/YATATests/SyncEngineTests.swift` | new | 17 test cases with MockURLProtocol stubbing and in-memory SwiftData container |
| `YATA/YATA.xcodeproj/project.pbxproj` | modified | Added SyncEngine.swift to YATA target and SyncEngineTests.swift to YATATests target |

## How to Test

```bash
xcodebuild -project YATA/YATA.xcodeproj -scheme YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' test 2>&1 | grep -E '(Test Suite|Test Case|Executed|BUILD|failed)' | tail -40
```

Expect: 77 tests, 0 failures, TEST SUCCEEDED. All 17 SyncEngineTests pass individually.

## Self-Check

- [x] Build succeeds (BUILD SUCCEEDED)
- [x] No new errors (existing warnings only: ModelContext non-Sendable in Swift 5 mode, AppDelegate no-async-in-await)
- [x] All 77 tests pass (0 failures)
- [x] All Definition of Done items from the brief are met

## Open Questions

- **Payload decoding approach:** The brief specified using `JSONDecoder` with `.convertFromSnakeCase` to decode PendingMutation payloads into request body structs. However, the request body structs (`CreateItemRequest`, etc.) are `Encodable`-only, and adding `Decodable` conformance via extension causes a Swift compiler crash (ICE in `swift-frontend`). Instead, I used `JSONSerialization` to decode the snake_case JSON payload into `[String: Any]` dictionaries and manually construct the request body structs. This achieves the same result but is less type-safe. The Architect should be aware of this limitation for A4 wiring -- if payload decoding needs to be more robust, the request body structs in `RequestBodies.swift` should be changed to `Codable` instead of `Encodable`.

- **MutationSnapshot pattern confirmed:** As anticipated in the brief's Open Questions, `PendingMutation` model objects cannot cross actor boundaries. The `MutationSnapshot` struct copies all primitive fields before leaving MainActor context. This pattern works correctly.

## Decisions Made

- Used `JSONSerialization` + manual struct construction instead of `JSONDecoder` for payload decoding (compiler crash forced this; see Open Questions above).
- Extracted `server_version` from the 409 error envelope (`{"error":{"code":"conflict","server_version":{...}}}`) with `JSONSerialization`, with a fallback to treating the entire body as the entity if the envelope is absent.
- For the `handleConflict` and `handleNotFound` methods, placed them in a `fileprivate` extension on `SyncEngine` to keep the main actor body focused on the happy path.

## Notes for Reviewer

- The `ModelContext` non-Sendable warnings are expected in Swift 5 mode when an actor captures a `ModelContext` and passes it into `MainActor.run {}` blocks. These will need to be addressed when migrating to Swift 6 strict concurrency, but are harmless in the current language mode.
- The `MockURLProtocol` in the test file is intentionally `private` and separate from the `StubURLProtocol` in `APIClientTests.swift` -- they have different APIs (handler-list vs single-handler) and should not be shared.
- No existing files were modified (except `project.pbxproj` for target membership).
