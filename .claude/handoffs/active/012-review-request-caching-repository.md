# Review Request

**Sequence:** 012
**Task:** caching-repository
**Date:** 2026-04-04
**Branch:** feat/caching-repository
**Responds to:** 011-architect-brief-caching-repository

## Summary

Built the offline mutation queue (A2) consisting of `PendingMutation` SwiftData model, `MutationLogger` service with queue compaction, and `CachingRepository` decorator that wraps `LocalTodoRepository` and `LocalRepeatingRepository`. All writes delegate to local storage first, then log a `PendingMutation` entry for future sync. Read-only methods pass through without logging. No network calls, no UI changes, no modifications to existing files.

## Files Changed

| File | Change | Description |
|------|--------|-------------|
| `YATA/YATA/Models/PendingMutation.swift` | new | SwiftData @Model for mutation queue entries (id, entityType, entityID, mutationType, payload, retryCount, lastError) |
| `YATA/YATA/Sync/MutationLogger.swift` | new | Service to log/fetch/delete/compact PendingMutation entries with snake_case JSON encoding |
| `YATA/YATA/Repository/CachingRepository.swift` | new | Decorator implementing TodoRepository + RepeatingRepository, delegates to local repos and logs mutations |
| `YATA/YATATests/MutationLoggerTests.swift` | new | 8 test cases for MutationLogger: log, ordering, delete, and all 3 compaction rules + entity type isolation |
| `YATA/YATATests/CachingRepositoryTests.swift` | new | 8 test cases for CachingRepository: add/update/delete delegation + logging, read-only passthrough, reorder, move, repeating add/delete |
| `YATA/YATA.xcodeproj/project.pbxproj` | modified | Added new files and Sync group to Xcode project |

## How to Test

```bash
# Build
xcodebuild -project YATA/YATA.xcodeproj -target YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' build 2>&1 | grep -E '(BUILD|error:|warning:)' | tail -20

# Run all tests
xcodebuild -project YATA/YATA.xcodeproj -scheme YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' test 2>&1 | grep -E '(Test Suite|Test Case|BUILD|error:|Executed|failed|passed)' | tail -40
```

Verify no existing files were modified: `git diff main --name-only` should show only new files plus project.pbxproj.

## Self-Check

- [x] `xcodebuild build` passes (BUILD SUCCEEDED, no new warnings)
- [x] `xcodebuild test` passes (60 tests, 0 failures)
- [x] All Definition of Done items from the brief are met
- [x] No changes to existing protocols, repositories, views, or app entry point

## Open Questions

- **MutationLogger context vs LocalTodoRepository context**: As noted in the brief, MutationLogger and LocalTodoRepository use separate `ModelContext` instances from the same container. Tests pass with this approach. Both auto-save, and SwiftData handles cross-context consistency.

## Decisions Made

- **Synthetic UUIDs for rollover/materialize**: Used `00000000-0000-0000-0000-000000000010` for rollover and `...0011` for materialize. These are deterministic so compaction collapses repeated calls.
- **EmptyPayload struct for deletes**: Used a private `EmptyPayload: Encodable` struct instead of raw string data, so the JSON encoder produces `{}` consistently.
- **RepeatingIDPayload for deleteOccurrences**: Created a minimal private struct with `repeatingId: UUID` field to produce the `{"repeating_id": "<uuid>"}` JSON payload (snake_case via encoder).
- **AnyEncodable wrapper**: Used a lightweight type-erased wrapper in MutationLogger to encode arbitrary `Encodable` payloads without generics on the `log` method signature.
- **Date formatter uses UTC**: The ISO 8601 date formatter is pinned to `en_US_POSIX` locale and UTC timezone, matching API contract conventions.

## Notes for Reviewer

- `PendingMutation` is registered in `ModelContainer` only in tests. Production registration is deferred to A4.
- The compaction `compact()` method groups by `(entityType, entityID)` key string, ensuring different entity types with the same UUID are treated independently.
- All 16 specified test cases are implemented and passing (8 in MutationLoggerTests, 8 in CachingRepositoryTests).
