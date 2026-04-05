# Review Request

**Sequence:** 008
**Task:** api-foundation
**Date:** 2026-04-04
**Branch:** feat/api-foundation
**Responds to:** 007-architect-brief-api-foundation

## Summary

Implemented Phase A1 of the API integration: added `updatedAt: Date?` to both SwiftData models, created the full networking layer (APIClient, Endpoint enum with all 21 API endpoints, APIError, and DTO types matching the API spec), deleted the obsolete `APITodoRepository` stub, and wrote comprehensive tests. The app builds and runs identically to before -- zero behavioral changes.

## Files Changed

| File | Change | Description |
|------|--------|-------------|
| `YATA/YATA/Models/TodoItem.swift` | modified | Added `var updatedAt: Date?` property after `rescheduleCount` |
| `YATA/YATA/Models/RepeatingItem.swift` | modified | Added `var updatedAt: Date?` property after `createdAt` |
| `YATA/YATA/Networking/APIClient.swift` | new | HTTP client with auth headers, JSON coding, and error mapping |
| `YATA/YATA/Networking/APIError.swift` | new | Typed error enum for all HTTP status codes |
| `YATA/YATA/Networking/Endpoint.swift` | new | Enum with all 21 API endpoints, computed path/method/query/body |
| `YATA/YATA/Networking/DTOs/APITodoItem.swift` | new | Codable DTO with conversion to/from TodoItem, plus DateFormatters |
| `YATA/YATA/Networking/DTOs/APIRepeatingItem.swift` | new | Codable DTO with conversion to/from RepeatingItem |
| `YATA/YATA/Networking/DTOs/RequestBodies.swift` | new | All request body Encodable structs |
| `YATA/YATA/Networking/DTOs/ResponseBodies.swift` | new | All response Codable structs including SyncResponse, ErrorResponse |
| `YATA/YATA/Repository/APITodoRepository.swift` | deleted | Obsolete stub replaced by new architecture |
| `YATA/YATA.xcodeproj/project.pbxproj` | modified | Added networking files, test files; removed APITodoRepository references |
| `YATA/YATATests/EndpointTests.swift` | new | 23 tests covering path, method, query params for all endpoints |
| `YATA/YATATests/DTOTests.swift` | new | JSON decode/encode round-trip tests for all DTOs and request bodies |
| `YATA/YATATests/APIClientTests.swift` | new | URLProtocol-stubbed tests for error mapping (401/404/409/422/500) |
| `YATA/YATATests/ModelMigrationTests.swift` | new | Verifies updatedAt defaults to nil and persists correctly |

## How to Test

```bash
# Build
xcodebuild -project YATA/YATA.xcodeproj -target YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' build 2>&1 | grep -E '(BUILD|error:|warning:)' | tail -20

# Test (60 tests, 0 failures)
xcodebuild -project YATA/YATA.xcodeproj -scheme YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' test 2>&1 | grep -E '(Test Suite|Test Case|BUILD|error:|Executed|failed)' | tail -40
```

Verify no behavioral change: launch the app on simulator, navigate between tabs, add/edit/delete items -- everything works as before.

## Self-Check

- [x] Build succeeds (BUILD SUCCEEDED)
- [x] No new compiler warnings (pre-existing AppDelegate warnings only)
- [x] All 60 tests pass (0 failures)
- [x] All Definition of Done items from the brief are met

## Open Questions

1. **`AnyCodable` in ResponseBodies.swift:** The `ErrorResponse.ErrorDetail.serverVersion` field is typed as `AnyCodable?` since the API spec shows it as a freeform JSON object. I implemented a minimal type-erased Codable wrapper. If the Architect prefers a different approach (e.g., raw `Data` or just `String?`), happy to change.

2. **Fractional seconds:** As noted in the brief, `DateFormatters.parseDateTime()` tries ISO8601 without fractional seconds first, then with fractional seconds as fallback. This handles both server response formats.

3. **`scheduledTime` conversion:** RepeatingItem stores `scheduledTime` as `Date`, but the API uses `"HH:mm:ss"` strings. The DTO conversion uses `DateFormatters.timeOnly` with UTC timezone to extract/inject time components. This loses the original date portion, which is expected since only the time component matters.

## Decisions Made

- **`APITodoItem.updatedAt` is `String?`** (not `String`) per the brief's Open Question #3. This handles local-only items where `updatedAt` is nil.
- **`Endpoint.bodyData(encoder:)` takes an external encoder** rather than creating its own, so APIClient can share a single configured encoder.
- **`APIClient` uses typed throws** (`throws(APIError)`) in internal methods for precise error propagation, with the public `request<T>` method using untyped `throws` since it can also throw `DecodingError` wrapped in `APIError`.
- **`StubURLProtocol` uses `nonisolated(unsafe)`** for the static response handler property, which is acceptable in test code and avoids actor isolation complexity.

## Notes for Reviewer

- The two pre-existing warnings in `AppDelegate.swift` (no async operations within await) are not from this change.
- The `AnyCodable` type is only used for the `server_version` field in error responses. It is intentionally minimal -- just enough to decode arbitrary JSON for conflict resolution in future steps.
- No Views, ViewModels, or the app entry point were modified. The networking layer is completely inert until CachingRepository (A2) connects it.
