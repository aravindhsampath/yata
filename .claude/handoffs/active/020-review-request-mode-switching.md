# Review Request

**Sequence:** 020
**Task:** settings-ui-mode-switching
**Date:** 2026-04-05
**Brief:** 019-architect-brief-mode-switching.md

## What Was Built
Implemented A4: Settings UI and mode switching. This is the final wiring step that connects the local-only app to the optional client/server sync infrastructure built in A1-A3. The app now supports two modes (local and client) switchable from Settings, with full server configuration UI, authentication flow, initial sync, and graceful disconnect.

## Files Changed
| File | Change |
|------|--------|
| `YATA/YATA/YATAApp.swift` | Added PendingMutation to ModelContainer schema, created RepositoryProvider as @State, injected into environment, added scenePhase sync trigger for client mode |
| `YATA/YATA/Views/HomeView.swift` | Removed inline LocalTodoRepository creation, reads RepositoryProvider from environment, added sync-on-refresh in client mode |
| `YATA/YATA/Views/RepeatingView.swift` | Removed inline repo creation, reads RepositoryProvider from environment |
| `YATA/YATA/Views/ContentView.swift` | Added SwiftData import, updated preview to include RepositoryProvider |
| `YATA/YATA/Views/SettingsView.swift` | Complete rewrite: added Server section with mode picker, URL field, health check, authentication, initial sync overlay, connected status display, Sync Now / Disconnect buttons |
| `YATA/YATA/AppDelegate.swift` | Added repositoryProvider property, notification handlers (Mark Done, Snooze, Tomorrow) now route through active repository for mutation logging in client mode, with fallback to direct context save |
| `YATA/YATA/Networking/APIClient.swift` | Added static `checkHealth(serverURL:)` and `authenticate(serverURL:secret:)` methods for pre-auth operations |
| `YATA/YATA.xcodeproj/project.pbxproj` | Added KeychainHelper.swift and RepositoryProvider.swift to project |

## Files Created
| File | Purpose |
|------|---------|
| `YATA/YATA/Services/KeychainHelper.swift` | Minimal Security framework wrapper with save/load/delete for Keychain storage of API token and server URL |
| `YATA/YATA/Services/RepositoryProvider.swift` | @Observable @MainActor class that owns mode-aware repository creation, SyncEngine lifecycle, switchToLocal/switchToClient/disconnect methods |

## How to Verify

1. **Build**: `cd YATA && xcodebuild -target YATA -destination 'platform=iOS Simulator,id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' -quiet build` -- should succeed with zero errors
2. **Tests**: `cd YATA && xcodebuild -scheme YATA -destination 'platform=iOS Simulator,id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' test` -- all 34 tests should pass
3. **Local mode regression**: Launch app in simulator. Default mode is "local". All CRUD operations on todos and repeating items should work identically to before.
4. **Settings UI**: Go to Settings tab. Verify "Server" section appears with Local/Client segmented control. Default is "Local".
5. **Client mode flow**: Switch to "Client", enter a server URL, verify health check runs. If server unreachable, verify red X status shown. If reachable, verify green checkmark, then secret field and Authenticate button appear.
6. **Disconnect**: After connecting, verify "Disconnect" button reverts to local mode and clears Keychain entries.
7. **Token in Keychain**: Verify token is never stored in UserDefaults (search code for "yata_api_token" -- only KeychainHelper references).

## Known Issues
- The `onChange(of: scenePhase)` in YATAApp produces a deprecation warning about the 1-parameter closure form. The 2-parameter form `{ _, newPhase in }` causes a compile error with the current Xcode/SDK combination, so the 1-parameter version is used. This is cosmetic only.
- The pre-existing deletion of `APITodoRepository.swift` was not included in this commit as it predates this work.
- No unit tests were added specifically for KeychainHelper or RepositoryProvider (these would require mocking the Keychain and are better suited for integration tests).

## Build Status
BUILD SUCCEEDED (zero errors)

## Test Status
TEST SUCCEEDED -- 34 tests in 3 suites passed
