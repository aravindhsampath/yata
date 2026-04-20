# YATA Client-Server Architecture Plan

## The Core Idea

YATA operates in two modes:

- **Local mode** — SwiftData is the database. No network. The app today.
- **Client mode** — A Rust API on the user's VPS is the source of truth. SwiftData becomes a local cache that enables smooth, offline-capable operation.

The user chooses their mode in Settings. The app feels identical in both — the same views, the same gestures, the same speed. The difference is invisible until you look at Settings or use a second device.

---

## Why This Architecture

The API is the source of truth. Local storage is a **read cache only** — it keeps the UI fast but never speaks on its own behalf. Every user action hits the server on the same call stack; the UI update and the server write are part of one await chain. This is the **write-through with optimistic UI** pattern (Linear, Proton). Offline in client mode is a real failure state: writes surface an error; reads come from the stale cache.

This replaced an earlier "optimistic local-first with deferred batch sync" design — that pattern created a divergence window (the interval between syncs) where local state and server state could silently disagree, and a failed push during that window silently discarded the local change. Write-through eliminates the window.

---

## The Two Modes in Detail

### Local Mode (unchanged)

```
User action → HomeViewModel → LocalTodoRepository → SwiftData
```

No network. No sync. `LocalTodoRepository` is the only repository implementation in use. This is YATA 1.0 as it always was.

### Client Mode (write-through)

```
User action → HomeViewModel → CachingRepository
                                    │
                                    ├── optimistic local write (SwiftData)
                                    ├── await api.request(…)   (server round-trip)
                                    └── reconcile server fields (updated_at, etc.)

On API error:
                                    ├── rollback local (add / move / reschedule)
                                    │   OR: rethrow; VM triggers SyncEngine.pull()
                                    └── error surfaces in ViewModel.errorMessage
```

`CachingRepository` wraps `LocalTodoRepository` + `APIClient`. The ViewModel doesn't know or care which mode it's in — the `TodoRepository` protocol is the same. `SyncEngine` is pull-only — there is no per-mutation push queue; writes are server-confirmed before control returns to the VM.

---

## Architecture Components

### Repository Layer

```
TodoRepository (protocol — unchanged)
    ├── LocalTodoRepository    (existing — SwiftData only)
    └── CachingRepository      (new — wraps LocalTodoRepository + SyncEngine)
```

`CachingRepository` implements `TodoRepository` by:
1. Delegating to `LocalTodoRepository` for immediate execution (the user sees results instantly)
2. Recording the mutation in a `PendingMutation` log
3. Asking `SyncEngine` to flush the log to the API

The ViewModel calls the same protocol methods regardless of mode. Mode switching is a repository swap at the app level.

### SyncEngine

The `SyncEngine` is the only component that talks to the network. It has three jobs:

1. **Push** — Replay pending mutations to the API
2. **Pull** — Delta sync via `GET /sync?since=<timestamp>`
3. **Reconcile** — Apply server state to local cache, resolve conflicts

```
SyncEngine
    ├── push()       — flush PendingMutation log to API
    ├── pull()       — delta sync, apply server changes to SwiftData
    ├── fullSync()   — push then pull (called on app foreground, connectivity restore)
    └── observe()    — watch for connectivity changes, trigger sync
```

### PendingMutation Log

A SwiftData model that persists unsent mutations:

```
@Model PendingMutation
    id: UUID
    createdAt: Date
    entityType: String        // "todoItem" or "repeatingItem"
    entityID: UUID
    mutationType: String      // "create", "update", "delete", "reorder", "move", "done", "undone", "reschedule", "rollover", "materialize"
    payload: Data             // JSON of the request body
    retryCount: Int
    lastError: String?
```

Mutations are recorded in order and replayed in order. This guarantees causal consistency — if you create an item then mark it done, the server sees both operations in the right sequence.

### APIClient

A thin HTTP client. No business logic — just request/response.

```
APIClient
    ├── Configuration: serverURL, token (stored in Keychain)
    ├── request<T: Decodable>(_ endpoint: Endpoint) async throws -> T
    └── Handles: auth headers, JSON encoding/decoding, error mapping
```

---

## Sync Strategy: The Full Picture

### When Does Sync Happen?

| Trigger | Action |
|---------|--------|
| App becomes active (foreground) | `fullSync()` — push then pull |
| After any local mutation (client mode) | `push()` — immediate attempt, queues on failure |
| Network connectivity restored | `fullSync()` |
| User pulls-to-refresh | `fullSync()` |
| Manual "Sync Now" in Settings | `fullSync()` |
| Periodic background (optional, iOS BGTaskScheduler) | `fullSync()` |

### Push: Sending Local Changes to Server

```
for each PendingMutation (ordered by createdAt):
    1. Build the API request from mutation payload
    2. Send to server
    3. On success:
       - Update local entity's `updated_at` with server's response
       - Delete the PendingMutation
    4. On 409 (conflict):
       - Server returns its current version in `server_version`
       - Overwrite local entity with server version
       - Delete the PendingMutation (server wins)
       - Log the conflict for debugging
    5. On 404:
       - Entity was deleted on server
       - Delete local entity
       - Delete the PendingMutation
    6. On network error:
       - Increment retryCount
       - Stop processing (preserve ordering)
       - Schedule retry with exponential backoff
    7. On 401:
       - Stop all sync
       - Surface "re-authenticate" prompt in UI
```

**Ordering matters.** If mutation #3 depends on mutation #2 (e.g., create then update), they must be sent in order. On failure, stop the queue — don't skip ahead.

**Compaction.** Before pushing, compact the queue:
- Multiple updates to the same entity → keep only the latest
- Create followed by delete of the same entity → remove both
- Create followed by updates → merge into a single create with final state

This reduces network round-trips and avoids sending stale intermediate states.

### Pull: Receiving Server Changes

```
1. GET /sync?since=<lastSyncTimestamp>
2. For each upserted item:
   - If local entity exists:
     - If local entity has a PendingMutation → skip (push will handle it)
     - Else → overwrite local with server version
   - If local entity doesn't exist → insert
3. For each deleted ID:
   - Remove local entity
   - Remove any PendingMutation for this entity
4. Update lastSyncTimestamp to server's `server_time`
```

**Critical rule:** Never overwrite a local entity that has pending mutations. The push phase handles those — pulling server state on top of unsent local changes would lose the user's work.

### Full Sync Flow

```
fullSync():
    1. push()        — send all pending mutations
    2. pull()        — fetch server changes since last sync
    3. Notify UI     — post .yataDataDidChange so HomeViewModel reloads
```

This order matters: push first, then pull. If we pulled first, we might overwrite local changes that haven't been sent yet.

---

## Conflict Resolution

### Philosophy

YATA is a personal todo app. One user, typically one active device. Conflicts happen when:
- The user edits on their phone, then edits on their iPad before the phone syncs
- The server runs a rollover/materialization while the app is making changes

These are rare. When they happen, **the server wins**. The user's most recent action (on whichever device synced last) is preserved. The overwritten change is lost — and for a todo app, this is acceptable. Nobody needs a three-way merge for "Call roof guy" vs "Call Stefan about roof."

### Conflict Detection

Every entity carries `updated_at`, set by the server on every mutation.

When the client pushes an update, it includes its local `updated_at`. The server compares:

```
if server.updated_at > client.updated_at:
    return 409 Conflict { server_version: current state }
else:
    apply update, set new updated_at = now()
    return 200 { updated entity }
```

### Conflict Scenarios

| Scenario | Detection | Resolution |
|----------|-----------|------------|
| Same item edited on two devices | 409 on second device's push | Server version wins. Second device overwrites local. |
| Item deleted on server, edited on client | 404 on push | Delete local copy. Mutation discarded. |
| Item edited on client, deleted on server via rollover | Pull shows item in `deleted` list | If pending mutation exists, push first (will get 404), then delete local. |
| Reorder on client, reorder on server | Push succeeds if sort_order update; 409 if other fields conflict | Server version wins for conflicts; reorder replays with current server state. |
| Repeating rule deleted on server while client has it | Pull shows rule in `deleted` list | Delete local rule and all undone occurrences. |

### What About Merge?

No merging. Merging implies combining two versions of an entity, which requires field-level diffing and creates surprising results. ("Why did my title change but my priority stayed?") For a personal app, LWW (last-write-wins) at the entity level is simpler, predictable, and sufficient.

If a conflict occurs on a meaningful change (e.g., the user notices their edit was lost), they simply re-edit. The cost of re-typing a todo title is near zero.

---

## Offline Behavior

### The User Experience

The app works identically offline. No spinners. No "you're offline" banners. No disabled buttons.

The only visible indicator: a subtle sync status icon in Settings showing "Last synced: 2 min ago" or "Pending: 3 changes." The user can ignore this entirely.

### What Happens When Offline

1. User creates/edits/deletes items → applied to SwiftData immediately
2. Each mutation is recorded in PendingMutation log
3. `SyncEngine.push()` fails silently (network error) → mutation stays queued
4. User continues working normally

### What Happens When Back Online

1. `SyncEngine` detects connectivity (NWPathMonitor)
2. `fullSync()` runs: push all pending mutations, then pull server changes
3. If any conflicts: server wins, local overwritten
4. UI refreshes via `.yataDataDidChange` notification

### Extended Offline (days/weeks)

If the user is offline for a long time:
- The PendingMutation log grows but stays ordered
- On reconnect, queue compaction runs first (dedup/collapse)
- Push replays all mutations — some may get 404/409 (entities changed/deleted on server)
- Each failure is handled individually (conflict resolution above)
- After push, delta pull catches up on everything the server did
- Worst case: a few user edits are silently overridden by server state

The server's deletion log must retain entries for at least 30 days. Clients offline longer than that should do a full sync (re-download everything) rather than a delta.

---

## Server-Side Responsibilities

These operations run on the server because they involve cross-item logic that shouldn't be duplicated in the client:

| Operation | Why server-side |
|-----------|----------------|
| **Materialization** | Must be atomic and deduplicated. Two clients materializing the same date range could create duplicates. |
| **Rollover** | Cross-date operation that must see the full picture. Running on two clients simultaneously could double-increment reschedule counts. |
| **Cascading deletes** | Deleting a repeating rule must delete all undone occurrences atomically. |
| **Sort order integrity** | Reorder operations set sort_order across all items in a lane. Must be serialized. |
| **Conflict resolution** | Server is the authority — it decides who wins. |
| **Deletion log** | Server maintains soft deletes or a deletion log for delta sync. |

### What the Client Triggers

The client still *triggers* materialization and rollover — the same way it does today. But in client mode, instead of executing the logic locally, it sends `POST /operations/materialize` or `POST /operations/rollover` to the server. The server executes, the client pulls the results.

```
// Local mode (today)
await repository.materializeRepeatingItems(for: dateRange)

// Client mode (CachingRepository delegates to API)
POST /operations/materialize { start_date, end_date }
// Then pull to get the created items
GET /sync?since=<lastSync>
```

---

## Client-Side Responsibilities

| Responsibility | Why client-side |
|----------------|----------------|
| **Optimistic UI** | User must see results immediately — can't wait for server round-trip |
| **Local cache** | SwiftData stores everything for offline access and instant reads |
| **Mutation queue** | Pending changes must survive app termination |
| **Local notifications** | UNUserNotificationCenter is device-local — server can't schedule these |
| **Notification scheduling** | Remains entirely client-side (Phase 1 foundation already built) |
| **Badge management** | Device-local concern |
| **Permission management** | iOS notification permissions are per-device |

---

## Migration Between Modes

### Local → Client (First-time setup)

```
1. User enters server URL in Settings
2. App checks GET /health — verify server is reachable
3. User enters secret → POST /auth/token — get bearer token
4. Token stored in Keychain
5. Initial sync:
   a. Push all local TodoItems to server (POST /items for each)
   b. Push all local RepeatingItems to server (POST /repeating for each)
   c. Server responds with server-set fields (updated_at, created_at)
   d. Update local entities with server-set fields
   e. Set lastSyncTimestamp = server_time from final response
6. Mode switched to "client" in @AppStorage
7. CachingRepository becomes active
```

**Edge case:** If the server already has data (e.g., user previously used client mode on another device), the initial sync must handle duplicates. Strategy: client sends items with their existing UUIDs. Server does upsert — if UUID exists, update; if not, create.

### Client → Local (Disconnect)

```
1. Pull latest from server (ensure cache is current)
2. Clear PendingMutation log
3. Clear server URL and token from Keychain
4. Mode switched to "local" in @AppStorage
5. LocalTodoRepository becomes active
6. All data remains in SwiftData — user loses nothing
```

### Server Wipe / Fresh Start

If the user wipes their server and reconnects:
- Initial sync pushes all local data to the empty server
- No conflicts — server has nothing to conflict with

---

## Settings UI for Client Mode

```
Server
  ├── Mode: [Local | Client]
  │
  │   (When Client is selected:)
  ├── Server URL: [https://yata.example.com]
  ├── Status: Connected ✓ / Unreachable ✗ / Authenticating...
  ├── Last synced: 2 min ago
  ├── Pending changes: 0
  ├── [Sync Now]
  └── [Disconnect] — reverts to local mode
```

**Connection test flow:**
1. User types URL → app pings `GET /health` on debounce
2. Green check if reachable, red X if not
3. On first connection: prompt for secret
4. After auth: initial sync begins with progress indicator

---

## UX Flows

### Normal Operation (Online, Client Mode)

```
User taps item to mark done
  → CachingRepository.markDone(item)
      → LocalTodoRepository.markDone(item)    [instant — UI updates]
      → PendingMutation(type: "done", id: item.id) recorded
      → SyncEngine.push()                     [background]
          → POST /items/{id}/done
          → Success → delete PendingMutation, update local updated_at
```

User sees the item disappear from active list and appear in done list instantly. The server learns about it milliseconds later.

### Offline Mutation

```
User creates an item (airplane mode)
  → CachingRepository.add(item)
      → LocalTodoRepository.add(item)         [instant — item appears]
      → PendingMutation(type: "create") recorded
      → SyncEngine.push()                     [fails — no network]
          → Mutation stays queued

... user turns off airplane mode ...

  → NWPathMonitor detects connectivity
  → SyncEngine.fullSync()
      → push: POST /items with queued item → success
      → pull: GET /sync?since=... → apply any server changes
```

### Conflict Recovery

```
Device A: rename "Call roof guy" → "Call Stefan about roof"
  → pushes to server → server updated_at = T1

Device B (stale cache): change priority of "Call roof guy" to Low
  → pushes to server with updated_at = T0
  → Server: T0 < T1 → 409 Conflict, returns version with title="Call Stefan about roof", priority=High
  → Device B: overwrites local with server version
  → Device B now shows "Call Stefan about roof" at High priority
  → The priority change from Device B is lost
```

This is correct behavior. The most recent edit (Device A's rename) is preserved. Device B's stale edit is discarded. If the user wanted both changes, they re-edit on Device B.

### App Launch (Client Mode)

```
App launches
  → HomeViewModel.loadAll()
      → CachingRepository.loadAll()
          → LocalTodoRepository returns cached data [instant — UI populated]
      → SyncEngine.fullSync() [background]
          → push pending mutations
          → pull server changes
          → if changes found → .yataDataDidChange notification
          → HomeViewModel.loadAll() again [UI updates silently]
```

The user sees their cached data immediately. If the server has changes (from another device, from rollover, from materialization), the UI updates within seconds. No loading spinner.

---

## Edge Cases

| Scenario | Handling |
|----------|---------|
| Server unreachable for weeks | App works in local mode with growing mutation queue. On reconnect: compact + push + pull. |
| Token expires mid-session | 401 on next push → surface re-auth prompt. Mutations stay queued. |
| Server clock skew | `updated_at` is server-authoritative. Client never sets it. Server uses UTC. |
| Client creates item, then deletes before push | Queue compaction: create + delete cancel out. Nothing sent to server. |
| Duplicate UUID on initial sync | Server does upsert by UUID. If UUID exists, treats as update. |
| App terminated with pending mutations | PendingMutation is a SwiftData @Model — survives app termination. Replayed on next launch. |
| Very large mutation queue (1000+) | Compaction reduces to essential mutations. Push in batches of 50. |
| Server returns 500 | Retry with exponential backoff (1s, 2s, 4s, 8s, max 60s). After 10 failures: stop auto-sync, surface error in Settings. |
| User changes server URL | Equivalent to disconnect + reconnect. Clears mutation log, does fresh initial sync. |
| Materialization race (two devices trigger simultaneously) | Server deduplicates by (source_repeating_id, scheduled_date). Second request is a no-op. |

---

## Implementation Phases

### Phase A: API Client + CachingRepository (Foundation)

- `APIClient` — HTTP layer with auth, error handling, retry
- `CachingRepository` — wraps `LocalTodoRepository`, records `PendingMutation`
- `PendingMutation` SwiftData model
- `SyncEngine` — push/pull/fullSync with queue compaction
- Settings UI — mode toggle, server URL, auth flow, sync status
- Mode switching in `YATAApp` (swap repository implementation)

### Phase B: Robust Sync

- `NWPathMonitor` integration — auto-sync on connectivity change
- Exponential backoff on failures
- Conflict resolution with server-wins policy
- Deletion log handling in delta sync
- Background sync via `BGTaskScheduler`

### Phase C: Migration

- Local → Client initial sync with progress UI
- Client → Local disconnect flow
- Handle server wipe / fresh start scenario

### Phase D: Rust API Server

- Actix-web or Axum server implementing the API spec
- PostgreSQL or SQLite backend
- Token auth middleware
- Materialization and rollover as server-side operations
- Soft delete / deletion log for sync
- Docker image for easy self-hosting

---

## What This Plan Does NOT Cover

- **Multi-user / sharing** — YATA is personal. One user per server instance.
- **Real-time push (WebSocket/SSE)** — Polling + pull-on-foreground is sufficient for a single user. Add later if multi-device responsiveness becomes a problem.
- **End-to-end encryption** — The user owns the server. HTTPS is sufficient. If they want E2EE, that's a separate concern.
- **Server-side notifications (APNs)** — Phase 1 notifications are local. Server-triggered push notifications are a future enhancement.
- **Attachments / file sync** — Todo items are text. No binary data sync.
