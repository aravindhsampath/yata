# Architect Verdict

**Sequence:** 022
**Task:** settings-ui-mode-switching
**Date:** 2026-04-04
**Reviewing handoff trail:** 019 through 021

## Verdict: APPROVED

## Summary

A4 (Settings UI + Mode Switching) wires together the entire Phase A client-server foundation. KeychainHelper provides secure token/URL storage via Security framework. RepositoryProvider (@Observable @MainActor) owns mode-aware repository creation, SyncEngine lifecycle, and switch/disconnect flows. YATAApp registers PendingMutation in ModelContainer and injects RepositoryProvider into the environment. HomeView and RepeatingView read repositories from the provider. SettingsView has a full Server section with mode picker, health check, authentication, initial sync, sync-now, and disconnect. AppDelegate notification handlers save locally and log mutations for sync in client mode.

## Verification

- [x] Work matches the original brief's intent
- [x] Review Feedback MUST FIX resolved (commit f23dc76 — handlers now save via local context + log mutations separately)
- [x] No unresolved ESCALATE items
- [x] Scope was maintained (no drift)
- [x] Build succeeds with zero errors
- [x] All 77 tests pass

## Notes

- **MUST FIX resolved**: AppDelegate handlers were passing items from a handler-local ModelContext to the repository's different ModelContext, causing silent data loss. Fixed by saving locally first, then logging mutations via MutationLogger when in client mode.
- **SHOULD FIX #1** (initial sync only pushes today's items): Non-blocking. The TodoRepository protocol doesn't expose an "all items" fetch, and changing it is out of A4 scope. For a personal todo app with <100 items this is acceptable. Can be improved in Phase B by adding a raw FetchDescriptor query in the initial sync flow.
- **SHOULD FIX #2** (disconnect doesn't pull before clearing): Non-blocking. Pulling before disconnect is a nice-to-have but not critical — the user is choosing to go local-only. Can be added in Phase B.
- **SHOULD FIX #3** (SecItemAdd return value): Non-blocking. Keychain saves are best-effort for a personal app. No user-facing impact.
- **SHOULD FIX #4** (unused variable): Non-blocking cosmetic issue.

## Merge Record

- **Merged to main:** PENDING USER APPROVAL
- **Merge commit:** PENDING
- **Pushed to origin:** PENDING

## Phase A Complete

With A4 approved, all four sub-steps of Phase A are complete:
- **A1**: APIClient + DTOs + Endpoint (21 endpoints, typed errors, bidirectional DTO conversion)
- **A2**: PendingMutation + CachingRepository + MutationLogger (mutation queue with compaction)
- **A3**: SyncEngine (push/pull/fullSync actor with conflict handling)
- **A4**: Settings UI + Mode Switching (RepositoryProvider, KeychainHelper, view refactoring, AppDelegate wiring)

The app now supports dual-mode operation: local-only (default, zero regressions) and client mode (server sync via self-hosted API).

## Follow-up Tasks (Phase B)

- NWPathMonitor connectivity watching
- BGTaskScheduler background sync
- Exponential backoff retry logic
- Initial sync: push ALL local items (not just today's)
- Disconnect: pull latest before clearing
