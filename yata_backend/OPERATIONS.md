# YATA Operations Runbook

Self-contained guide for running, observing, deploying, and
recovering the YATA backend. The intended reader is *future you*
sshing into the prod box at 2am with no recent context. Every
section is meant to stand alone — skip around as needed.

Companion docs:
- `README.md` — first-time install (one-shot, build once and forget).
- `deployment/README.md` — what each artifact in `deployment/` is
  for and how to install the staging unit.
- `../YATA/docs/hardening_plan.md` — historical context on why each
  P0/P1/P2/P3 change exists.

---

## 0. Layout

| Path | Purpose |
|---|---|
| `/usr/local/bin/yata_backend` | Live binary (server + admin CLI). |
| `/usr/local/bin/yata_backend.prev` | One-step rollback (manually populated, see §3). |
| `/etc/systemd/system/yata.service` | Production unit. |
| `/etc/systemd/system/yata-staging.service` | Staging unit (port 3001). |
| `/etc/systemd/system/yata-backup.{service,timer}` | Nightly `VACUUM INTO` snapshot job. |
| `/etc/yata/yata.env` | Prod env file (mode 0640, root:yata). |
| `/etc/yata/yata-staging.env` | Staging env file. |
| `/var/lib/yata/yata.db` | Prod SQLite DB + `-wal` + `-shm`. |
| `/var/lib/yata-staging/yata.db` | Staging DB. |
| `/var/backups/yata/yata-*.db` | Nightly backups (14-day retention). |

Caddy fronts both units on `yata.aravindh.net` and
`staging.yata.aravindh.net`. Direct ports `:3000` and `:3001` are
firewalled off from the public internet.

---

## 1. Prerequisites (one-time, on a fresh box)

```sh
# Rocky Linux 10 / Alma 10. Adjust pkg manager for Debian/Ubuntu.
sudo dnf install -y systemd caddy sqlite openssl jq
# A current Rust toolchain — only needed if building on the box.
# CI bakes the binary in pull requests; copying it across is fine.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
```

The service runs as a dedicated `yata` system user with a locked
password and `/var/lib/yata` as its home — created once via
`useradd --system --home /var/lib/yata --create-home yata`.

---

## 2. Deploying a new version

The standard flow is: build, restart prod, smoke-test, done.

```sh
# On the build host (or directly on the box):
cd ~/yata && git pull
cargo build --release --manifest-path yata_backend/Cargo.toml

# Stage the rollback target BEFORE replacing the live binary —
# this is the recovery rope you'd otherwise wish you had.
sudo cp /usr/local/bin/yata_backend /usr/local/bin/yata_backend.prev

# Install + restart.
sudo install -m 0755 yata_backend/target/release/yata_backend /usr/local/bin/yata_backend
sudo systemctl restart yata

# Verify.
curl -s https://yata.aravindh.net/health      # {"status":"ok",...}
curl -s https://yata.aravindh.net/health/db   # {"status":"ok"}
curl -s https://yata.aravindh.net/version     # {"git_sha":"...","built_at_epoch":"..."}
sudo journalctl -u yata --since '1 minute ago' -o cat | tail -20
```

Migrations run automatically at startup via `sqlx::migrate!` —
embedded at compile time, no separate migration step.

If the deploy crosses a breaking change (new auth flow, schema
shape, etc.), do staging first (§9) then prod.

---

## 3. Rolling back

If `/health/db` is red, response times explode, or new structured
errors flood the journal:

```sh
sudo cp /usr/local/bin/yata_backend.prev /usr/local/bin/yata_backend
sudo systemctl restart yata
journalctl -u yata --since '1 minute ago' -o cat
```

This restores the previous binary in <2 seconds. **It does not roll
back schema migrations** — sqlx forward-only design assumes you
fix forward. If a migration is the problem:

1. Stop the service: `sudo systemctl stop yata`.
2. Restore the most recent good backup over the live DB (§7).
3. Pin the previous binary (above), restart.
4. Investigate offline; do NOT push another deploy until the
   broken migration is removed from `migrations/`.

---

## 4. Reading logs

The server emits JSON-structured logs to journald via
`tracing-subscriber` (see `src/observability.rs`, P0.3). Each HTTP
request gets a span with method, URI, and an `x-request-id` that
also appears as a response header so client errors are
correlatable.

```sh
# Plain text (drops journald metadata, prints just the log lines):
sudo journalctl -u yata --since '1 hour ago' -o cat

# Structured — pipe through jq for filtering/transforming:
sudo journalctl -u yata --output=json-pretty | jq '.MESSAGE | fromjson?' | head

# Tail live:
sudo journalctl -u yata -f -o cat

# Only errors:
sudo journalctl -u yata -p err --since today

# Follow a specific request id reported by a user:
sudo journalctl -u yata --since '1 hour ago' -o cat | grep '"request_id":"<id>"'
```

`RUST_LOG` in `/etc/yata/yata.env` controls verbosity. `info`
default; bump to `debug` temporarily for noisy investigation, then
`systemctl restart yata` to reset.

---

## 5. Rotating `YATA_JWT_SECRET`

Rotate when:
- The secret may have leaked (commit history, journal, etc.).
- A scheduled cycle (every 6–12 months for hygiene).

**Caveat: this invalidates every existing token across every user.**
Mobile apps will surface a 401 on next request and prompt the user
to re-enter their password. There is no per-user impact otherwise.

```sh
NEW_SECRET=$(openssl rand -hex 32)
sudo sed -i "s|^YATA_JWT_SECRET=.*|YATA_JWT_SECRET=$NEW_SECRET|" /etc/yata/yata.env
sudo systemctl restart yata
journalctl -u yata --since '1 minute ago' -o cat | grep 'tracing initialized'
```

The staging secret in `/etc/yata/yata-staging.env` is independent
and **should never match prod**. A token minted against staging
must not decode against prod and vice versa.

---

## 6. User management

All admin actions go through the same binary as the server.

```sh
# Create a user. Prompts twice for the password (min 8 chars).
sudo -u yata YATA_JWT_SECRET=$(grep ^YATA_JWT_SECRET /etc/yata/yata.env | cut -d= -f2) \
  YATA_DB_PATH=/var/lib/yata/yata.db \
  yata_backend create-user alice

# Or with stdin (useful for scripts):
echo 'correct horse battery staple' | sudo -u yata ... yata_backend create-user alice --password-stdin

# List users:
sudo -u yata ... yata_backend list-users

# Reset a user's password. ALSO bumps password_changed_at, which
# invalidates every token they currently hold (logout-all-devices).
# See P0.5: tokens with `iat` earlier than the user's
# password_changed_at fail verification.
sudo -u yata ... yata_backend reset-password alice

# Delete a user. Cascade removes all linked todo_items,
# repeating_items, and deletion_log rows.
sudo -u yata ... yata_backend delete-user alice

# Per-user stats (P3.22) — useful for spotting dormant tenants.
sudo -u yata ... yata_backend stats
```

For convenience, drop a wrapper in your shell rc:

```sh
yata-admin() {
  sudo -u yata env $(sudo cat /etc/yata/yata.env | xargs) yata_backend "$@"
}
# Now: `yata-admin list-users`, `yata-admin stats`, etc.
```

---

## 7. Backups & restore

A nightly systemd timer runs `yata_backend backup` which uses
SQLite's `VACUUM INTO` to produce a consistent snapshot without
quiescing the live server. See `deployment/yata-backup.{service,timer}`.

```sh
# List backups (newest first):
ls -lh /var/backups/yata/

# Validate a backup:
sqlite3 /var/backups/yata/yata-2026-04-22-030000.db 'PRAGMA integrity_check;'
# Expected: "ok"

# Take an ad-hoc backup right now:
sudo systemctl start yata-backup.service
sudo journalctl -u yata-backup --since '1 minute ago' -o cat
```

**Restore (destructive — make a copy of the live DB first):**

```sh
sudo systemctl stop yata
sudo cp /var/lib/yata/yata.db /var/lib/yata/yata.db.preserve
sudo install -o yata -g yata -m 0640 \
  /var/backups/yata/yata-<chosen>.db /var/lib/yata/yata.db
# WAL/SHM are recreated automatically on next open; remove stale ones:
sudo rm -f /var/lib/yata/yata.db-wal /var/lib/yata/yata.db-shm
sudo systemctl start yata
curl -s https://yata.aravindh.net/health/db
```

If users had data committed between the backup and the restore,
that data is lost. Communicate accordingly before pulling the
trigger.

---

## 8. Emergency: corrupted DB

Symptoms: `/health/db` returns 503, journal shows `database disk
image is malformed` or repeated SQLITE_CORRUPT errors.

Two recovery paths, in order of preference:

1. **Promote the latest good backup** (§7). If the corruption is
   recent, you lose at most 24 hours of writes.

2. **`sqlite3 .recover`**: dumps as much SQL as can be salvaged,
   then re-imports. Lossy but worth trying when a backup isn't
   available.

```sh
sudo systemctl stop yata
cd /var/lib/yata
sqlite3 yata.db.broken '.recover' > recovered.sql
sqlite3 -batch yata.recovered.db < recovered.sql
sqlite3 yata.recovered.db 'PRAGMA integrity_check;'
# If "ok":
sudo install -o yata -g yata -m 0640 yata.recovered.db /var/lib/yata/yata.db
sudo rm -f /var/lib/yata/yata.db-wal /var/lib/yata/yata.db-shm
sudo systemctl start yata
```

If both paths fail, the box has bigger problems (disk failing, FS
corruption). Pull the most recent backup off-box and rebuild from
scratch.

---

## 9. Staging deploys

The staging unit (`yata-staging.service`) on port 3001 is the
rehearsal stage for breaking migrations or new endpoints. Same
binary, separate DB, separate JWT secret.

```sh
# Deploy:
sudo cp /usr/local/bin/yata_backend.staging.prev /usr/local/bin/yata_backend
sudo install -m 0755 target/release/yata_backend /usr/local/bin/yata_backend
sudo systemctl restart yata-staging

# Smoke-test against staging URL:
curl -s https://staging.yata.aravindh.net/health
curl -s https://staging.yata.aravindh.net/version

# Test against staging from the iOS simulator: point Settings at
# https://staging.yata.aravindh.net, log in as a staging user.
```

When happy, repeat §2 for prod. The staging DB is treated as
disposable — wipe and recreate when its schema diverges from prod
in ways that would interfere with rehearsal.

---

## 10. Branch-protection / CI status

Branch protection on `main` requires the three GitHub Actions
checks (P2.16) to be green before merge:

- `backend` — cargo fmt, clippy -D warnings, cargo test.
- `ios` — xcodebuild test on macos-15.
- `ats-check` — Release `Info.plist` must not contain
  `NSAppTransportSecurity` (P1.10 invariant).

Configure under **Settings → Branches → Branch protection rules**
on GitHub: require pull request reviews, require status checks,
list the three above. Enforce on admins.

---

## 11. Smoke-test cheatsheet (post-deploy)

Quick checklist after every prod restart:

```sh
# Liveness + readiness:
curl -fsS https://yata.aravindh.net/health
curl -fsS https://yata.aravindh.net/health/db
# Build identity:
curl -fsS https://yata.aravindh.net/version | jq
# Auth round-trip:
TOKEN=$(curl -fsS -X POST https://yata.aravindh.net/auth/token \
  -H 'content-type: application/json' \
  -d '{"username":"<a-real-user>","password":"<their-password>"}' | jq -r .token)
curl -fsS https://yata.aravindh.net/items \
  -H "authorization: Bearer $TOKEN" | jq '.items | length'
# Recent activity:
sudo -u yata ... yata_backend stats
# Logs clean:
sudo journalctl -u yata --since '5 minutes ago' -p err
# (Empty output = no errors logged. Good.)
```

If any step is red, roll back (§3) and investigate offline.
