# YATA Client–Server Architecture

## The Core Idea

YATA runs in one of two modes, chosen per-device in Settings:

- **Local mode.** SwiftData is the only store. No network. This is the app's original behavior and remains the default when no server is configured.
- **API (server) mode.** A self-hosted Rust backend is the source of truth. SwiftData becomes a read cache for the UI. Every write goes through the server on the same call stack.

The user toggles modes in Settings → Sync. The app looks identical in both. The only visible difference is the Sync section (and, in API mode, the user's username).

---

## Why This Architecture

Local storage is a **cache for reads only**. It keeps the UI fast but never speaks on its own behalf. Every user action — add, edit, done, move, reorder, reschedule, delete — hits the server on the same `await` chain that the ViewModel's optimistic local write happens on. The API call is not batched, queued, or deferred.

This is the **write-through with optimistic UI** pattern (Linear, Proton Drive, Zed). The UI updates instantly, the request goes out immediately, and either the server acks (and we reconcile server-set fields back into the local cache) or it doesn't (and we surface the error — and where cheap, rollback the local change).

**Offline in API mode is a real failure state.** Writes surface an error message; reads still work from the stale cache. If you need full offline operation, use Local mode.

### What this replaced

The original design was "optimistic local-first with a deferred batch sync." Mutations were recorded to a `PendingMutation` SwiftData log and pushed later by `SyncEngine.push()`. This opened a divergence window (the interval between syncs) where local state could silently disagree with the server, and a failed push during that window would apply `handleConflict` — which overwrote the local change with server state and deleted the mutation, silently discarding user input.

Write-through eliminates the window. A successful return from a repository method means the server has acknowledged.

---

## The Two Modes in Detail

### Local Mode (unchanged)

```
User action → HomeViewModel → LocalTodoRepository → SwiftData
```

No network. No sync. `LocalTodoRepository` is the only repository in use. `SyncEngine`, `APIClient`, and `CachingRepository` are never instantiated. This is YATA 1.0 behavior.

### API Mode (write-through)

```
User action → HomeViewModel → CachingRepository
                                   │
                                   ├── optimistic local write  (LocalTodoRepository → SwiftData)
                                   ├── await apiClient.request(…)
                                   └── reconcile server-set fields (updated_at, completed_at)

On API failure:
                                   ├── rollback local state if cheap
                                   │     (add / move / reschedule — snapshotted before mutation)
                                   ├── else rethrow; caller triggers SyncEngine.fullSync()
                                   │     to reseed the cache from server truth
                                   └── error surfaces via ViewModel.errorMessage
```

The ViewModel doesn't know which mode it's in — the `TodoRepository` / `RepeatingRepository` protocols are the same. Mode switching is a repository swap in `RepositoryProvider`.

---

## Architecture Components

### Repository layer

```
TodoRepository       (protocol — unchanged across modes)
RepeatingRepository  (protocol — unchanged across modes)
    ├── LocalTodoRepository + LocalRepeatingRepository   (SwiftData only)
    └── CachingRepository                                 (API mode — implements both)
```

`CachingRepository` composes a `LocalTodoRepository` + `LocalRepeatingRepository` + an `APIClient`. On every write it does the four steps above; on every read it delegates straight to the local repo (no network call on the read path).

### SyncEngine (pull-only)

`SyncEngine` no longer pushes anything. Its only job in write-through mode is pulling the server's delta so the local cache picks up changes made on **other** devices or by server-side operations (materialization, rollover).

Triggers:

| Trigger | Method |
|---|---|
| Scene becomes `.active` | `syncIfStale(minInterval: 30)` |
| Network reconnect | `syncIfStale(minInterval: 30)` |
| `BGAppRefreshTask` fires | `syncIfStale(minInterval: 30)` |
| User taps "Sync now" | `fullSync()` directly |
| User taps "Disconnect" | `fullSync()` best-effort before teardown |
| A write fails in a ViewModel | `fullSync()` from `handleWriteError()` |

`syncIfStale` coalesces the first three triggers (which can overlap on flaky networks). User intent (sync now, disconnect) is never coalesced.

### APIClient

Thin HTTP client. Bearer-token authenticated (token in the Keychain). Methods: `request<T>(_ endpoint)`, `requestNoContent(_ endpoint)`, and two pre-auth statics (`checkHealth`, `authenticate`). Emits typed `APIError` cases (`unauthorized`, `notFound`, `conflict`, `validationError`, `serverError`, `networkError`, `invalidURL`, `decodingError`). Everything else in the app handles network I/O through this one type.

---

## Sync Flow

### Writes (API mode)

```
1. ViewModel optimistically mutates the item in place (e.g. item.isDone = true)
2. ViewModel calls `try await repository.update(item)`
3. CachingRepository.update:
   a. try local.update(item)               — save locally so the UI is persistent
   b. try await apiClient.request(PUT …)   — same call stack
   c. reconcile server fields back into item
4. On thrown error:
   - update / reorder            : rethrow; VM's catch triggers pull
   - add                          : try? local.delete(item); rethrow
   - move                         : try? local.move(item, to: oldPriority); rethrow
   - reschedule                   : restore oldDate + oldCount; rethrow
   - delete                       : nothing to rollback; rethrow
```

There is **no mutation log** and **no push**. Each write lives entirely within the method that triggered it.

### Pull (API mode only)

```
1. GET /sync?since=<yata_lastSyncTimestamp>
2. For each upserted TodoItem / RepeatingItem:
     - if an item with that id exists locally → overwrite fields from server
     - else → insert
3. For each deleted id: if present locally, delete
4. Save the ModelContext
5. UserDefaults.yata_lastSyncTimestamp = response.server_time
```

Note: pull does **not** guard against "local pending mutations" like the old design did — in write-through mode the cache has no unacked local writes to protect. If anything is pending server-side, it's because a previous write failed; the VM already has the error surfaced.

---

## Conflict Semantics

Server is authoritative. When a client update is pushed with a stale `updated_at`, the server's handler parses both timestamps with `chrono::DateTime::parse_from_rfc3339` (`yata_backend/src/time.rs`) and returns 409 if its version is strictly newer. The iOS client receives the 409 and rethrows — the ViewModel's `handleWriteError` fires a pull which replaces the local copy with server truth.

There is no field-level merge. For a personal todo app with one user on ~two devices, LWW at the entity level is predictable and sufficient.

**Historical note:** an earlier version of the client formatted `updated_at` as `"yyyy-MM-dd"` (date only), which compared lexically-less than every RFC3339 timestamp on the server and triggered a false 409 on every update. Fixed by switching the client to ISO8601 **and** by making the server compare as `DateTime` values. Either fix alone would have closed the bug.

---

## Offline Behavior

### Local mode
Everything works offline. No-op change.

### API mode
- **Reads**: served from the SwiftData cache, which is whatever the last pull populated. Stale but functional.
- **Writes**: throw `APIError.networkError`. The ViewModel surfaces a message; if the mutation is on a type that supports rollback (add/move/reschedule), the local state is restored.
- **Sync triggers while offline**: `SyncEngine.fullSync()` throws `SyncError.networkUnavailable`; backoff increments. On network reconnect, `NetworkMonitor` fires `syncIfStale()` which clears the backoff and pulls.

There is no banner, no blocking spinner. The user sees the cache; if they write, they see the error inline. If truly offline operation is needed for the whole app, Local mode is the answer.

---

## Server-Side Responsibilities

These stay server-side because they involve cross-entity logic that is unsafe to duplicate across clients:

| Operation | Why server-side |
|---|---|
| Materialization | Dedups `(source_repeating_id, scheduled_date)` so two clients triggering it can't double-create occurrences. |
| Rollover | Bulk `scheduled_date` + `reschedule_count` update across all overdue items for that user. |
| Cascading delete | `DELETE /repeating/:id` wipes undone child `todo_items`. |
| Reorder integrity | The server rewrites `sort_order` for all ids in a lane atomically. |
| Deletion log | So that pull can distinguish "never existed here" from "deleted since last pull." |

### What the client triggers

iOS `CachingRepository` still exposes `rolloverOverdueItems(to:)` and `materializeRepeatingItems(for:)` via the same protocol `LocalTodoRepository` does. In API mode those methods mutate locally first then call `POST /operations/rollover` / `POST /operations/materialize`. The server performs the real work; iOS's local-first pass is just to make the UI feel instant — a pull on next trigger reconciles.

---

## Client-Side Responsibilities

| Responsibility | Why client-side |
|---|---|
| Optimistic UI | User sees results before any round-trip completes. |
| Read cache | SwiftData backs every read in both modes. |
| Local notifications | `UNUserNotificationCenter` is device-only; server never schedules. |
| Badge | Device-local. |
| Permission state | Per-device. |

---

## Mode Transitions

### Local → API (first connect)

1. User taps "Connect to server…" in Settings → sheet opens.
2. User enters URL + username + password → taps Connect.
3. Sheet runs `GET /health`, then `POST /auth/token` → token stored in Keychain, username in Keychain, URL in Keychain.
4. `RepositoryProvider.switchToClient` rebuilds the repository stack (`CachingRepository` now active).
5. The sheet runs a one-time backfill: iterates existing local `TodoItem`s and `RepeatingItem`s and POSTs them to the server. The server does upsert-by-id so repeated connects are idempotent.
6. `SyncEngine.fullSync()` runs to set `yata_lastSyncTimestamp` and catch up any server-side state.
7. Sheet dismisses. Settings now shows the connected account.

### API → Local (disconnect)

1. User taps Disconnect in Settings → native confirmation alert.
2. On confirm: `serverMode = "local"` flips immediately (UI updates).
3. Background: `RepositoryProvider.disconnect()` runs a best-effort pull, then clears Keychain + `yata_lastSyncTimestamp`, switches back to plain `LocalTodoRepository`.

The SwiftData cache is left in place — nothing gets wiped. The user keeps all their tasks; they just stop syncing.

---

## Settings UI

Current layout:

```
Sync
  ├─ (if not connected) "Connect to server…" button
  │                     footer: "Local mode: tasks live only on this device…"
  │
  └─ (if connected)
       Server               yata.example.com
       Signed in as         alice
       Last sync            …
       Retry/halted row     (only when SyncEngine is retrying or halted)
       Sync now             (Button)
       Disconnect           (Button, destructive, with confirm alert)

Appearance
  └─ Color scheme picker

Recently Done
  └─ Show last (10 / 25 / 50 / 100)

About
  └─ Version
```

The "Connect to server…" button presents a modal `ServerConnectSheet` with URL / username / password fields, a nav-bar Cancel + Connect, password visibility toggle, focus chain (`next → next → go`), and inline error text for bad URL / unreachable / wrong credentials.

---

## What This Document Does NOT Cover

- **Multi-tenancy on the server.** Covered in [`API_spec.md`](API_spec.md). The server hashes passwords with Argon2id, scopes every query by `user_id`, provisions accounts via CLI (`yata_backend create-user`).
- **The Rust backend's internals.** Axum + sqlx + SQLite. See [`../../yata_backend/`](../../yata_backend/) and its `README.md` for deploy instructions.
- **The `yata` CLI.** See [`../../yata_cli/README.md`](../../yata_cli/README.md). Uses the same REST API as iOS.
- **End-to-end encryption.** Out of scope — the user controls the server; HTTPS is sufficient.
- **Real-time server push (SSE / WebSocket).** Pull-on-foreground is sufficient for a single-user two-device workflow. Worth revisiting if a third device joins and inter-device latency becomes painful.
- **Shared or multi-user accounts.** Each YATA account is a solo todo list. Sharing a list with someone else is not in scope.
