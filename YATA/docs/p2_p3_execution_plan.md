# P2 + P3 execution plan

**Companion to:** `YATA/docs/hardening_plan.md` (master plan, with the
locked-in decisions table) and `YATA/docs/onboarding_review.md` (the
original SRE-perspective review that produced the 22-item list).

This document is **self-contained** so a fresh agent (post-compaction)
can pick up exactly where we stopped without rereading the chat
history. Every item below has: scope, files, test strategy, design
choices already settled, and a one-line "branch off main" command.

---

## State at handoff (2026-05-06)

Everything pushed to `main`. 12 of 22 items shipped:

| Phase | Items | Net effect |
|---|---|---|
| **P0** (ops floor) | 1–5 | WAL + tuned PRAGMAs, local backups via `VACUUM INTO` + systemd timer, `tracing-subscriber` + `tower-http` request-id correlation, per-IP rate limit on `/auth/token`, JWT 7-day + `/auth/refresh` + `password_changed_at` revocation. |
| **Hotfix** | post-merge smoke test | `axum::serve` wired with `into_make_service_with_connect_info::<SocketAddr>()` so `SmartIpKeyExtractor` works on direct-to-server traffic. New `tests/e2e_socket.rs` locks it in. |
| **P1** (correctness) | 6–11 | Safe BGTask downcast (`as!` → `as?`), graceful ModelContainer recovery + `DataStoreErrorView`, AppDelegate `awaitContainer` closes cold-launch race, two-plist split for ATS hardening in Release, dead conflict-detection code removed, notification-action handlers routed through `repositoryProvider.todoRepository` instead of separate ModelContext + manual API mirror. |

**Tests on main:**
- `cargo test` → 65 (was 11 pre-hardening; -6 from deleting `time.rs` in P1.11)
- `xcodebuild test` (YATATests) → 90 (was 73)

**Outstanding branches** (not on main):
- `ui-redesign` — token refresh + warm palette + bundled Inter/JetBrainsMono fonts. Experiment, not for main without explicit ask.

**Live deployment:**
- `yata.aravindh.net` (Caddy in front of `yata_backend` systemd unit on `46.224.136.170`)
- Has NOT been redeployed since the P0/P1 merges. Doing so will:
  - Invalidate all existing tokens (P0.5: tokens lacking `iat` decode-fail → users log in once each).
  - Require WAL + new `password_changed_at` migration → handled automatically by `sqlx::migrate!` on first start.
  - Start logging JSON to journald and stamping `x-request-id` on responses.

---

## What the next agent should run on first start

```sh
git -C /Users/aravindhsampathkumar/ai_playground/yata status   # confirm clean main
cd /Users/aravindhsampathkumar/ai_playground/yata/yata_backend && cargo test --quiet
cd /Users/aravindhsampathkumar/ai_playground/yata/YATA && xcodebuild test -scheme YATA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:YATATests 2>&1 | grep "Executed"
```

Expected: 65 backend tests pass, 90 iOS tests pass. If anything is
red on `main`, stop and report — something else has happened.

After that, proceed item by item below. Each item's branch is taken
**off latest main**. Don't stack — every commit went straight to main
in P0+P1 via `--ff-only`, and that should continue.

---

# P2 — correctness corners (5 items)

## P2.12 — Done-item retention

**Branch:** `feat/done-retention`
**Effort:** ~4 h
**Risk:** 🔴 (deletes user data)
**Decision (locked):** **Default = forever; user can pick a shorter
retention in Settings.** Never delete by default.

### Why

Completed `todo_items` accumulate forever. Years of use → multi-MB
table, slow `SELECT * WHERE user_id = ? AND is_done = 1 ORDER BY
completed_at DESC LIMIT 25`. The home view paginates the *display*;
storage is unbounded.

### Implementation

**Backend:**

1. **Migration** `yata_backend/migrations/003_done_retention.sql`:
   ```sql
   ALTER TABLE users ADD COLUMN done_retention_days INTEGER;
   -- NULL means "keep forever" (the default for existing + new users)
   ```

2. **`yata_backend/src/handlers/operations.rs`** — new handler `cleanup_done`:
   - Body: `{ "older_than_days": Optional<i64> }`. If absent, use
     the user's `done_retention_days`. If still NULL, return 200
     with `{ "deleted": 0 }` and no DELETE.
   - Query:
     ```sql
     DELETE FROM todo_items
     WHERE user_id = ?
       AND is_done = 1
       AND completed_at < datetime('now', ? || ' days')
     ```
     (Bind the negative number, e.g. `-90`.)
   - Don't forget the `deletion_log` insert per row (consistency
     with the `delete_item` handler).
   - Wrap in a transaction.
   - Return `{ "deleted": <count> }`.

3. **Routes** — add `POST /operations/cleanup-done` to the
   protected router in `routes.rs`.

4. **CLI** subcommand `yata_backend cleanup --user <username> [--older-than-days N]`:
   - Fallback to user's `done_retention_days`.
   - Useful for cron-driven offline cleanup.
   - Add `clap` subcommand entry next to existing
     `Backup`, `CreateUser`, etc. in `main.rs`.

5. **`PUT /users/me/preferences`** — new endpoint or extend an
   existing one — to set `done_retention_days`. Recommend a tiny
   new handler in `handlers/preferences.rs` for clean isolation.
   Body: `{ "done_retention_days": <i64 or null> }`.

**iOS:**

1. **`YATA/YATA/Views/SettingsView.swift`** — under "Recently Done",
   add a Picker bound to `@AppStorage("doneRetentionDays")`. Options:
   `nil` ("Keep forever"), `30`, `90`, `180`, `365`.
2. **`Networking/Endpoint.swift`** + **DTOs** — add
   `setPreferences(body:)` and `cleanupDone(body:)` endpoints.
3. **`HomeViewModel`** — call `cleanupDone()` on app foreground when
   `serverMode == "client"` and user has a non-nil retention.

**Local mode:** `LocalTodoRepository` gets a `cleanupDone(olderThanDays:)`
method that does the equivalent SwiftData fetch+delete.

### Tests

`yata_backend/tests/cleanup.rs`:
- 3 done items at varying ages (today, 31d, 100d), retention=90 →
  asserts the 100d item gone, others intact.
- retention=null → no-op.
- cross-tenant: user A's cleanup must not touch user B's items.
- `deletion_log` row created for each deleted item.

iOS:
- `LocalTodoRepositoryTests` gains a cleanup test mirroring the
  backend logic.
- A snapshot or unit test on the SettingsView picker isn't worth it.

### Risks

- **Destructive default**: keep retention=NULL on new users for
  safety. The CLI cleanup also defaults to no-op without explicit
  `--older-than-days`.
- **Sync interaction**: cleanup must produce `deletion_log` rows so
  paired devices remove the items via `/sync` delta. Without this,
  device A cleans up but device B keeps showing them.

---

## P2.13 — `/sync` pagination

**Branch:** `feat/sync-pagination`
**Effort:** ~4 h
**Risk:** 🟡 (clients that don't loop see stale data)
**Decision (locked):** Page size **500**.

### Why

`/sync?since=...` returns every upserted/deleted row in one shot. A
device offline for a year that comes back will receive thousands of
rows and OOM the iOS client (or hit axum's default 30s timeout).

### Implementation

**Backend** (`yata_backend/src/handlers/sync.rs`):

1. Accept query param `?limit=500` (default 500, max 1000).
2. SELECT items + repeating + deletion_log with `LIMIT ? + 1` so
   we can detect "has more" without a second query (read N+1, return
   first N if count > N).
3. Response shape additions:
   ```json
   {
     "items":     { "upserted": [...], "deleted": [...] },
     "repeating": { "upserted": [...], "deleted": [...] },
     "has_more":  true,
     "next_since": "2026-04-23T11:08:09.123Z"
   }
   ```
   `next_since` is the largest `updated_at` (or `deleted_at`) in
   the page, not wall-clock now. Lets the client loop without
   missing rows that share the previous page's high watermark.

**iOS** (`YATA/YATA/Sync/SyncEngine.swift`):

1. `SyncEngine.pull()` becomes a loop:
   ```swift
   var since = currentSince
   while true {
       let response = try await apiClient.request(.sync(since: since, limit: 500))
       apply(response)
       guard response.hasMore else { break }
       since = response.nextSince
   }
   persist(since)
   ```
2. `SyncResponse` DTO gets `hasMore: Bool` and `nextSince: String`.
3. The iOS-side `since` cursor stored in
   `UserDefaults["yata_lastSyncTimestamp"]` already exists; just
   advance it from `next_since`.

### Tests

`yata_backend/tests/sync_pagination.rs`:
- Insert 1500 items, GET `/sync?since=epoch&limit=500`, expect 500
  items + `has_more=true` + non-empty `next_since`.
- Follow-up GET with the returned `next_since` returns next page.
- After 3 pages (500+500+500) all rows are accounted for and
  `has_more=false`.
- Edge: deletion_log entries also paginate — insert 600 deletions,
  verify same loop covers them.

iOS `LiveServerIntegrationTests`:
- Gated test (only with `YATA_LIVE_TEST=1`) that creates 50 items,
  forces `since` back to epoch, calls `pull()`, asserts all 50
  appear locally. (Production page size makes 500-row pagination
  impractical to test via simulator without seeding 1k rows; this
  is a smaller smoke.)

### Risks

- Old iOS clients that don't loop see the first page only and look
  stale. Coordinate the deploy: ship iOS first (with the loop —
  `has_more=false` always on old servers means no behavior change),
  then deploy server. **Order: client first, server second.**

---

## P2.14 — `/health/db` + `/version`

**Branch:** `obs/health-and-version`
**Effort:** ~1 h
**Risk:** 🟢 additive

### Why

`GET /health` returns `{"status":"ok"}` regardless of DB pool state.
A connection-pool exhaustion or stuck-on-startup migration still
returns 200. Operators have no way to ask "which build is running"
without ssh'ing into the box.

### Implementation

**Backend:**

1. **`yata_backend/src/handlers/health.rs`** — add `db_health` handler:
   - Run `sqlx::query("SELECT 1").fetch_one(&pool)` with a 1s timeout.
   - Return 200 `{"status":"ok"}` on success, 503
     `{"status":"degraded","detail":"db unreachable"}` on failure.
2. **`build.rs`** (new file at `yata_backend/build.rs`):
   ```rust
   fn main() {
       let sha = std::process::Command::new("git")
           .args(["rev-parse", "--short", "HEAD"])
           .output()
           .ok()
           .and_then(|o| String::from_utf8(o.stdout).ok())
           .map(|s| s.trim().to_string())
           .unwrap_or_else(|| "unknown".into());
       println!("cargo:rustc-env=GIT_SHA={sha}");
       let now = chrono::Utc::now().to_rfc3339();
       println!("cargo:rustc-env=BUILT_AT={now}");
       println!("cargo:rerun-if-changed=../.git/HEAD");
   }
   ```
   (chrono needs to be in `[build-dependencies]` too, or compute the
   timestamp via `std::time::SystemTime`.)
3. **`yata_backend/src/handlers/health.rs::version`** handler:
   ```rust
   #[derive(Serialize)]
   struct VersionResponse {
       git_sha: &'static str,
       built_at: &'static str,
       version: &'static str,
   }
   pub async fn version() -> Json<VersionResponse> {
       Json(VersionResponse {
           git_sha: env!("GIT_SHA"),
           built_at: env!("BUILT_AT"),
           version: env!("CARGO_PKG_VERSION"),
       })
   }
   ```
4. **`routes.rs`** — add `/health/db` and `/version` to the
   `health` sub-router (no auth required).

### Tests

`yata_backend/tests/health.rs`:
- `/health/db` returns 200 with status=ok in test setup.
- `/version` returns non-empty `git_sha`, `built_at`, `version`
  fields. (Don't assert exact values; build.rs picks them at
  compile time.)
- Drop-the-pool test: hard. Skip the 503 path or mock with a closed
  pool if the existing `test_helpers` allows.

### Risks

None. Both endpoints are additive and unauthenticated (deliberately
so for monitoring probes).

---

## P2.15 — Staging environment runbook

**Branch:** `infra/staging`
**Effort:** ~1 h on the box
**Risk:** 🟢 (operator-facing only)
**Decision (locked):** **Same box as prod**, separate systemd unit.

### Why

There's one server. Every migration goes straight to prod with no
rehearsal. The first time a migration is broken, it's broken
in front of the user.

### Implementation

**No code changes** — purely operator runbook + a second systemd unit.

1. New `yata_backend/deployment/yata-staging.service` — copy of the
   existing `yata.service` with:
   - `EnvironmentFile=/etc/yata/yata-staging.env`
   - Different `YATA_DB_PATH=/var/lib/yata-staging/yata.db`
   - Different `YATA_PORT=3001`
2. Caddy block on the server:
   ```
   staging.yata.aravindh.net {
       reverse_proxy 127.0.0.1:3001
   }
   ```
3. **`yata_backend/OPERATIONS.md`** (this lands in P3.21) gets a
   "Staging" section with the deploy → migrate → smoke-test flow.

### Tests

No Swift / Rust tests. Operator validates by running:
```sh
curl https://staging.yata.aravindh.net/health
yata_backend create-user staging-test  # against the staging DB
```

### Risks

- Same-box failure mode: if the box is overloaded, prod and staging
  both go down. Acceptable for personal-scale; revisit if YATA
  ever gets multi-tenant beyond a single user.

---

## P2.16 — GitHub Actions CI

**Branch:** `infra/ci`
**Effort:** ~1.5 h
**Risk:** 🟢
**Decisions (locked):** **GitHub-hosted runners.** **Block merges on
red CI.**

### Why

The 65 backend + 90 iOS tests exist but nothing forces them to run
before a merge. One stale `try!` away from a regression nobody
catches.

### Implementation

1. **`.github/workflows/backend.yml`**:
   - Trigger: `push` to any branch + `pull_request` targeting main.
   - Runner: `ubuntu-latest`.
   - Steps:
     - `actions/checkout@v4`
     - `dtolnay/rust-toolchain@stable`
     - `actions/cache@v4` keying on `Cargo.lock` for `~/.cargo` and
       `target/`.
     - `cd yata_backend && cargo fmt --check`
     - `cd yata_backend && cargo clippy --all-targets -- -D warnings`
     - `cd yata_backend && cargo test`
   - Strict timeout: `timeout-minutes: 15`.

2. **`.github/workflows/ios.yml`**:
   - Trigger: same.
   - Runner: `macos-15` (or whatever's current with Xcode 16+).
   - Steps:
     - `actions/checkout@v4`
     - `sudo xcode-select -s /Applications/Xcode_16.0.app` (pin)
     - `xcodebuild test -scheme YATA -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:YATATests`
   - Cache `~/Library/Developer/Xcode/DerivedData` (be careful —
     can balloon, key on Cargo.lock + project.pbxproj hash).

3. **`.github/workflows/ats-check.yml`**:
   - One-step asserts `plutil -extract NSAppTransportSecurity raw`
     fails on the **Release** Info.plist build product. Locks
     in P1.10.

4. **Branch protection** (manual GitHub setting): require all
   three checks to pass before merge to main. Document in
   OPERATIONS.md.

### Tests

CI itself runs the existing test suites. No new unit tests.

### Risks

- Free macOS runner minutes are limited (~2k/month for private
  repos). Optimize by skipping iOS CI on docs-only commits using
  `paths-ignore`.

---

# P3 — niceties (6 items)

## P3.17 — Idempotency-Key middleware

**Branch:** `feat/idempotency-keys`
**Effort:** ~6 h
**Risk:** 🔴 (touches every write handler)
**Decision (locked):** **Implement now**, even though current
write-through architecture doesn't auto-retry. Defends against future
network-stack changes and gives the iOS app a clean retry story.

### Why

Today, a retried PUT after a network hiccup will either succeed
twice (creating duplicates) or 422 on UNIQUE-violation. Idempotency
keys let the server recognize duplicates by client-minted UUID.

### Implementation

**Backend:**

1. Migration `004_idempotency.sql`:
   ```sql
   CREATE TABLE idempotency_keys (
       key TEXT PRIMARY KEY NOT NULL,
       user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
       request_method TEXT NOT NULL,
       request_path TEXT NOT NULL,
       response_status INTEGER NOT NULL,
       response_body BLOB NOT NULL,
       created_at TEXT NOT NULL
   );
   CREATE INDEX idx_idempotency_user_created ON idempotency_keys(user_id, created_at);
   ```
2. New `src/middleware/idempotency.rs`:
   - Layer reads `Idempotency-Key` header.
   - If absent → call inner handler unchanged.
   - If present + record exists for `(user_id, key)` → return cached
     response with same status + body.
   - If present + new → call inner, persist `(status, body, …)` on
     success (2xx only — 4xx/5xx not cached so retries can succeed).
3. Sweep job: drop entries older than 24h on startup (or via a
   periodic task).
4. Apply only to write methods (POST/PUT/DELETE).

**iOS:**
1. `APIClient.request` mints a UUID per outbound write and adds the
   header.
2. Persist the key alongside the optimistic local change so a retry
   from a different process uses the same key.

### Tests

`tests/idempotency.rs`:
- Same key replayed → same response, no second row inserted.
- Different keys → two distinct rows (the normal multi-write case).
- 4xx errors NOT cached (a 422 followed by a corrected retry
  succeeds normally).
- Cross-tenant: user A's key does not collide with user B's same
  key string (scoped by `user_id`).

### Risks

- Schema growth — 24h sweep keeps it bounded.
- Body cache size — set a reasonable max (`response_body BLOB`
  limited to e.g. 64KB; bigger bodies just don't cache, retry would
  re-hit the handler).

---

## P3.18 — Drop `PendingMutation`

**Branch:** `chore/drop-pending-mutation`
**Effort:** ~1 h
**Risk:** 🟡 (SwiftData migration must drop the type cleanly)

### Why

`PendingMutation` was the offline-write-queue model from before the
write-through refactor. The model is registered in
`ModelContainer(for: TodoItem.self, RepeatingItem.self,
PendingMutation.self)` but no code reads or writes rows of this
type.

### Implementation

1. Delete `YATA/YATA/Models/PendingMutation.swift`.
2. Remove from `ModelContainer(for:)` calls in `YATAApp.swift`,
   `DataStoreLoader.swift`, every `#Preview` block, and every test
   that constructs an in-memory container.
3. Update `YATA.xcodeproj/project.pbxproj` to drop the file from
   PBXBuildFile, PBXFileReference, group children, and Sources
   build phase.
4. Add a migration test that opens an old store containing
   `PendingMutation` rows and verifies the new schema reads cleanly.
   SwiftData drops unknown entities transparently — but verify.

### Tests

`YATA/YATATests/ModelMigrationTests.swift` gains:
```swift
func test_oldSchemaWithPendingMutation_opensCleanly() throws {
    // Build a container with the old model set, insert a PendingMutation,
    // close, reopen with the new (no-PendingMutation) set, expect success.
}
```

### Risks

- SwiftData's behavior with disappeared models is technically
  documented but battle-tested only in-house. The migration test is
  the safety net.

---

## P3.19 — Argon2 params docs

**Branch:** `docs/argon2-params`
**Effort:** ~30 min
**Risk:** 🟢

### Why

Default `Argon2id` params (`m=19456 KiB / t=2 / p=1`) are adequate
today but undocumented. Future maintainers don't know when to bump.

### Implementation

1. Update `yata_backend/README.md` with a "Password hashing"
   section: parameters chosen, why they're acceptable now, when to
   bump (e.g. when CPU benches show <50ms/hash).
2. Update `yata_backend/src/password.rs` with a comment block:
   - Cite OWASP 2024 Argon2id recommendations for context.
   - Document `Argon2::default()` resolves to the values above.

### Tests

None — pure docs.

---

## P3.20 — MetricKit telemetry (iOS)

**Branch:** `obs/metrickit`
**Effort:** ~2 h
**Risk:** 🟢 (additive, on-device only)
**Decision (locked):** **MetricKit only.** No third-party SDK.

### Why

We have no signal from the iOS client today. First user complaint
of "app is slow" leaves us blind. MetricKit aggregates on-device
(privacy-friendly, App Store-safe).

### Implementation

1. **`YATA/YATA/Services/MetricsCollector.swift`** (new):
   - Conforms to `MXMetricManagerSubscriber`.
   - On payload delivery, append a JSON entry to
     `Documents/yata-metrics-<yyyy-mm-dd>.log`. Rotate daily; keep
     7 days.
2. **`YATA/YATA/YATAApp.swift`** — subscribe at launch behind a
   `@AppStorage("metricsEnabled")` flag (default `true`).
3. **`YATA/YATA/Views/SettingsView.swift`** — add toggle "Send
   diagnostics" (sets `metricsEnabled`) + a "Send to developer"
   button that opens `MFMailComposeViewController` with the most
   recent log file attached. No background upload.

### Tests

- Wrap `MXMetricManager` access behind a small protocol so a stub
  can deliver a fake payload in tests.
- Test: payload delivery results in a file written under
  `tempDir/yata-metrics-*.log` with valid JSON.
- Test: rotation keeps only the 7 newest log files.

### Risks

- MetricKit payloads are not constructible directly (Apple's API
  doesn't expose `init`). Use a thin protocol seam for testability.

---

## P3.21 — `OPERATIONS.md` runbook

**Branch:** `docs/operations-runbook`
**Effort:** ~1.5 h
**Risk:** 🟢

### Why

Onboarding gap. New owner of the box should be able to read one
document and know how to: deploy, redeploy, roll back, restart, see
logs, restore from backup, rotate JWT secret, create a user, run
the staging unit, see metrics.

### Implementation

`yata_backend/OPERATIONS.md` with sections:

1. **Prereqs** — Rocky Linux 10, systemd, Caddy, sqlite3, openssl.
2. **Deploy a new version**: ssh, `git pull`, `cargo build --release`,
   `systemctl restart yata`. Document log expectations.
3. **Roll back**: keep one prior `target/release/yata_backend` as
   `target/release/yata_backend.prev`; restoration is `mv` + `restart`.
4. **Read logs**: `journalctl -u yata --since '1 hour ago' -o cat`
   (drops journald metadata; the JSON is the inner line). Or
   `journalctl -u yata --output=json-pretty | jq` for structured.
5. **Rotate `YATA_JWT_SECRET`**: `openssl rand -hex 32`, edit
   `/etc/yata/yata.env`, `systemctl restart yata`. **Invalidates
   every existing token across every user.**
6. **User management**: `yata_backend create-user`, `list-users`,
   `delete-user`, `reset-password`. Document the
   `password_changed_at` revocation effect.
7. **Backups & restore**: where `/var/backups/yata/yata-*.db` live,
   how to validate (`sqlite3 backup.db 'PRAGMA integrity_check;'`),
   and the restore path (`systemctl stop yata`, copy backup over
   `/var/lib/yata/yata.db`, restart).
8. **Staging deploy** flow (see P2.15).
9. **Emergency: corrupted DB** — promote latest backup or run
   `sqlite3 .recover`.

### Tests

None.

---

## P3.22 — `yata_backend stats` admin CLI

**Branch:** `feat/admin-stats`
**Effort:** ~1 h
**Risk:** 🟢

### Why

Operator can't tell who's actively using the system without
ad-hoc `sqlite3` queries. A `stats` subcommand prints per-user
counts.

### Implementation

`yata_backend/src/main.rs` gets a `Stats` clap subcommand:

```rust
Command::Stats => cmd_stats(&pool).await,

async fn cmd_stats(pool: &SqlitePool) {
    // Single SELECT: users LEFT JOIN aggregates of todo_items + repeating_items
    // ORDER BY last_activity DESC NULLS LAST
}
```

Output:
```
USERNAME  ITEMS_OPEN  ITEMS_DONE  REPEATING  LAST_ACTIVITY
alice     142         418         7          2026-04-22T11:08:09Z
bob       3           14          0          2026-04-19T08:14:53Z
```

### Tests

`yata_backend/tests/stats_cli.rs`:
- Seed two users with varying counts.
- Invoke `cmd_stats` (factor out a pure-function `compute_stats(&pool)`
  for unit testing; the CLI wrapper just prints).
- Assert table contents match.

---

# Sequencing recommendation

A reasonable **two-week shape**:

**Week 1** — operator pain, lowest risk, biggest visibility wins:
1. P2.14 (`/health/db` + `/version`) — 1h, additive
2. P2.16 (CI) — 1.5h, additive
3. P2.15 (staging unit + Caddy block) — 1h, additive (operator only)
4. P3.21 (OPERATIONS.md) — 1.5h, additive
5. P3.22 (stats CLI) — 1h, additive
6. P3.19 (argon2 docs) — 30min, docs

**Week 2** — correctness corners, higher risk:
7. P3.18 (drop `PendingMutation`) — 1h, schema drop with migration test
8. P2.13 (`/sync` pagination) — 4h, client-then-server deploy ordering
9. P2.12 (done retention) — 4h, destructive default off; UI + handler
10. P3.20 (MetricKit) — 2h, additive iOS
11. P3.17 (idempotency keys) — 6h, last because it touches every write

---

# What stays untouched

- `RepositoryProvider`, `SyncEngine`, `MutationLogger`,
  `LocalTodoRepository` — battle-tested.
- `KeychainHelper`, `APIClient.buildRequest`, `axum` `Extension`
  pattern — known-good.
- The conflict-detection redesign (`updated_at` is server-authoritative).
  Don't reintroduce optimistic concurrency without monotonic int
  versions — see `YATA/docs/conflict_resolution_redesign.md`.

---

*Generated 2026-05-06, post P1.9 merge. Tests on main: 65 backend +
90 iOS. All decisions in `YATA/docs/hardening_plan.md` are locked
in; this document just expands them into actionable per-item
runbooks.*
