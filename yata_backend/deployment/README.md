# yata_backend deployment artifacts

Files here are installed on the prod box (`46.224.136.170`) — they
are not consumed by `cargo build`. Treat them as the source of
truth for what's running in production; if you change a unit on the
box without updating the file here, future-you will be confused.

## Files

| File | Installed at | Purpose |
|---|---|---|
| `yata.service` | `/etc/systemd/system/yata.service` | Production backend daemon. Listens on `YATA_PORT` (3000 by convention). |
| `yata-staging.service` | `/etc/systemd/system/yata-staging.service` | Staging instance. Same binary, separate DB at `/var/lib/yata-staging/yata.db`, separate port (3001), separate JWT secret. |
| `yata-backup.service` | `/etc/systemd/system/yata-backup.service` | One-shot `yata_backend backup` invocation, called from the timer. |
| `yata-backup.timer` | `/etc/systemd/system/yata-backup.timer` | systemd timer that triggers the backup service nightly. |
| `Caddyfile.staging` | Imported from `/etc/caddy/Caddyfile` | Caddy reverse-proxy block for `staging.yata.aravindh.net` → `127.0.0.1:3001`. |

## Initial staging install (one-time)

```sh
# As root on the prod box:
sudo mkdir -p /var/lib/yata-staging
sudo chown yata:yata /var/lib/yata-staging

# Drop a separate env file. The JWT secret MUST be different from
# prod so tokens can't cross-decode.
sudo install -m 0640 -o root -g yata /dev/stdin /etc/yata/yata-staging.env <<'EOF'
YATA_JWT_SECRET=<run: openssl rand -hex 32>
YATA_DB_PATH=/var/lib/yata-staging/yata.db
YATA_PORT=3001
RUST_LOG=info
EOF

# Install + enable the unit.
sudo install -m 0644 yata-staging.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yata-staging

# Caddy: append the staging block to the main Caddyfile, then reload.
sudo cp Caddyfile.staging /etc/caddy/conf.d/yata-staging
sudo systemctl reload caddy

# Smoke test.
curl https://staging.yata.aravindh.net/health
curl https://staging.yata.aravindh.net/version
```

## Day-to-day staging deploy

```sh
# Build a fresh release on the box (or scp the binary from CI):
cd /opt/yata && git pull && cargo build --release --manifest-path yata_backend/Cargo.toml
sudo install target/release/yata_backend /usr/local/bin/yata_backend
sudo systemctl restart yata-staging

# Migrations run automatically at startup via sqlx::migrate!.
# Verify:
sudo journalctl -u yata-staging --since '1 minute ago'

# Validate against staging URL with the iOS app or curl. When you're
# happy:
sudo systemctl restart yata
```

## Rolling back staging

```sh
# Keep the previous binary as `.prev` before each deploy:
sudo cp /usr/local/bin/yata_backend /usr/local/bin/yata_backend.prev
# Roll back:
sudo mv /usr/local/bin/yata_backend.prev /usr/local/bin/yata_backend
sudo systemctl restart yata-staging
```

## Why same-box?

Personal-scale: single user, low RPS, no SLA. A second cloud VM is
overkill; a same-box second systemd unit gives us migration
rehearsal and breaking-API testing for ~zero cost. If YATA ever
grows, move staging to its own VM — the unit file is portable.

If the prod box is overloaded, prod and staging both go down. That
risk is acceptable here; revisit if multi-tenant traffic shows up.
