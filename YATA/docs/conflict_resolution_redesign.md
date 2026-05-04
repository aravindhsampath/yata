# Drop optimistic concurrency on writes

**Status:** proposed → implemented on `fix/drop-optimistic-conflict`.
**Date:** 2026-04-23.

## The recurring bug

Marking an item done in API mode shows:
> Error — The item was modified on the server. Please refresh and try
> again.

This is the **fourth** time we've patched this same class of bug in the
last six weeks:

1. **2026-04-15** — `updated_at` serialized as a date-only string while
   the server stored RFC3339 → every PUT was a 409.
2. **2026-04-18** — server emitted nanosecond precision; client echoed
   whole-second; lexical compare flagged "newer" → every PUT was a 409.
3. **2026-04-20** — `scheduled_date` formatted in UTC instead of local
   time → tasks vanished from "today" after a sync; partly the same
   serialization-fragility problem.
4. **2026-04-23 (now)** — yet another wall-clock-skew or precision case;
   the user's bug report is still pending diagnosis but the symptom is
   identical to the prior three.

Each fix was a patch on a fundamentally fragile primitive: **wall-clock
RFC3339 strings as a revision token for optimistic concurrency**. That
primitive requires the client and server to agree on:

- Timezone serialization
- Fractional-second precision
- Round-trip parse/format symmetry across two languages
- Wall-clock alignment (NTP drift, container time skew)

We've patched each of those individually. The fundamental problem is
that **wall-clock time is the wrong primitive for revision tracking.**

## What we actually need

Look at YATA's real properties:

- **Single-user.** Each tenant is one human.
- **Usually one active device.** Phone or iPad, rarely both at once.
- **Write-through architecture.** Every API-mode mutation hits the
  server immediately; there is no batched offline-sync queue racing
  with foreground edits.
- **Pull-on-foreground.** Background pulls (`/sync?since=...`) reconcile
  cross-device divergence within ~30s of the second device coming
  active.
- **Cost of a "lost write" is low.** If two devices race on the same
  item within the same second, the loser is invisible to the user; the
  user notices and re-applies. No data integrity harm.
- **Cost of a false 409 is high.** Every false 409 produces a popup
  the user must dismiss, on an action that *did succeed locally* — the
  worst kind of dishonest error UI.

The trade is not close. We do not have a multi-writer concurrency
problem, but we keep paying the cost of an optimistic-concurrency
solution.

## The fix

**Drop the conflict check entirely. Server is authoritative on
`updated_at`. Client never claims to know it.**

Concretely:

### Backend (Rust)

1. `update_item` in `src/handlers/items.rs`: remove the
   `is_server_newer(&existing.updated_at, &body.updated_at)` block. Keep
   the 404-existence check (the SELECT on the row before UPDATE).
2. `update_repeating` in `src/handlers/repeating.rs`: same.
3. `UpdateItemRequest` / `UpdateRepeatingRequest`: make `updated_at`
   `Option<String>`, never read. Removing the field would break
   compatibility with any client still in the wild; keep it accepted
   and ignored.
4. `src/time.rs::is_server_newer`: keep the function and its tests as
   pure-utility documentation of why the lexical-compare approach was
   wrong, but it is no longer wired into any handler. Mark with
   `#[allow(dead_code)]` if clippy complains.
5. Remove tests that assert `409` from `update_item` /
   `update_repeating` handlers. The conflict test in
   `tenant_isolation.rs` for cross-tenant id collision (which returns
   422 via the unique-constraint path) stays — that's a different code
   path.

### Client (Swift)

1. `Networking/DTOs/RequestBodies.swift`: drop the `updatedAt` field
   from `UpdateItemRequest` and `UpdateRepeatingRequest`.
2. `Repository/CachingRepository.swift`: remove the `updatedAt:` line
   from both `updateRequest(from:)` and `updateRepeatingRequest(from:)`.
3. `AppDelegate.swift::logMutation`: same — drop the `updatedAt:` line.
4. `Networking/APIClient.swift`: remove the `case 409: throw
   .conflict(...)` mapping. If a 409 ever comes back from a stale
   server, treat it as a generic 4xx — a user-actionable error rather
   than a swallowed conflict.
5. `Networking/APIError.swift`: remove `case conflict` and its
   user-facing string. Anything that previously caught
   `APIError.conflict` should compile-fail cleanly so we audit each
   call site.
6. The `reconcile(server:into:)` path in `CachingRepository` still
   reads the server's `updated_at` from the response and stores it on
   the local `TodoItem` — so the `/sync?since=...` delta engine still
   works correctly; we just stop *sending* it back.

## What we're giving up

Cross-device write conflict detection. If two devices both edit the
same row within ~1 second of each other while both are online, the
later request wins and the earlier write is lost. The user can re-edit.

This was *already* the practical behavior — the optimistic check has
been so fragile that we've been disabling it via patches anyway, and
when it did fire it was usually a false positive. We're now making
the trade explicit instead of accidental.

## When this trade-off would change

- If we add multi-user collaboration on a shared list.
- If the offline-write-queue ever returns (it was removed in
  `refactor(ios): write-through API mode, pull-only SyncEngine`).
- If background-task syncs become more frequent than user edits.

In any of those cases, the right replacement is **monotonic
integer version numbers** (`version INT NOT NULL DEFAULT 0`,
incremented by the server on every UPDATE, sent back by the client on
its next write, server rejects with 409 if mismatched). That has none
of the wall-clock fragility of `updated_at`. We do not need it now.

## Migration

Zero. The server stops checking; the client stops sending. Existing
data is unaffected. Existing clients that *do* send `updated_at` are
silently ignored.

## Validation

- `cargo test` — all backend tests pass; the conflict-flagging tests
  are removed (not changed to expect a different status — they no
  longer represent valid behavior).
- `xcodebuild test` — all 73 iOS tests pass.
- Manual: mark a task done 5 times in a row, on the live server. No
  popup. Pull-to-refresh after, confirm server has the same state.
