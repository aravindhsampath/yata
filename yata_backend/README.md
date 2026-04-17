# YATA Backend

Self-hosted multi-tenant sync server for the YATA iOS app. Axum + sqlx + SQLite. One binary for both the server and admin CLI.

## Requirements

- Linux x86_64 or aarch64 (tested on Debian 12, Ubuntu 22.04+)
- Rust 1.80+ (only needed to build; the release binary has no runtime toolchain dependency)
- Port 3000 reachable from your iOS device (or a reverse proxy in front on 443)

## 1. Build

On the server:

```sh
sudo apt-get update && sudo apt-get install -y build-essential pkg-config git curl
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source "$HOME/.cargo/env"

git clone https://github.com/aravindhsampath/yata.git
cd yata/yata_backend
cargo build --release
```

Binary lands at `target/release/yata_backend` (~8 MB, statically linked against musl if you use the musl target — glibc otherwise).

Cross-compiling from macOS is also fine; install the matching Rust target and use `cross` if you hit toolchain issues.

## 2. Install

```sh
sudo install -m 0755 target/release/yata_backend /usr/local/bin/yata_backend
sudo useradd --system --home /var/lib/yata --create-home yata
```

The binary has no install-time dependencies beyond libc.

## 3. Configure

Three environment variables:

| Var | Required | Default | Purpose |
|---|---|---|---|
| `YATA_JWT_SECRET` | yes | — | Server-side JWT signing key. Long random string. **Not** a user password. |
| `YATA_DB_PATH` | no | `yata.db` (cwd) | SQLite file path. Will be created if missing. |
| `YATA_PORT` | no | `3000` | Listen port. Server binds `0.0.0.0`. |

Generate a strong secret once:

```sh
openssl rand -hex 32
```

Store it somewhere only root + the `yata` service can read (see systemd unit below).

## 4. Create users

The same binary is the admin CLI. Run as the service user so the DB file gets the right owner:

```sh
sudo -u yata \
  YATA_JWT_SECRET=<secret> \
  YATA_DB_PATH=/var/lib/yata/yata.db \
  yata_backend create-user alice
```

You'll be prompted for the password twice (min 8 chars, argon2id-hashed). Repeat for every user.

Other subcommands:

```sh
yata_backend list-users
yata_backend reset-password alice
yata_backend delete-user alice      # cascades: removes all their data
yata_backend --help
```

## 5. systemd service

Create `/etc/systemd/system/yata.service`:

```ini
[Unit]
Description=YATA sync backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=yata
Group=yata
WorkingDirectory=/var/lib/yata
EnvironmentFile=/etc/yata/yata.env
ExecStart=/usr/local/bin/yata_backend
Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=/var/lib/yata
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
```

Create `/etc/yata/yata.env` (mode `0640`, owner `root:yata`):

```ini
YATA_JWT_SECRET=<your-32-byte-hex-from-openssl>
YATA_DB_PATH=/var/lib/yata/yata.db
YATA_PORT=3000
RUST_LOG=info
```

Enable and start:

```sh
sudo install -d -m 0750 -o root -g yata /etc/yata
sudo install -m 0640 -o root -g yata yata.env /etc/yata/
sudo systemctl daemon-reload
sudo systemctl enable --now yata
sudo systemctl status yata
journalctl -u yata -f
```

## 6. Reverse proxy with HTTPS (recommended)

iOS enforces App Transport Security. Running over plain HTTP works only if you keep the dev ATS exception or use a local network. For any real deployment, put nginx or Caddy in front with a TLS cert (Let's Encrypt).

**Caddy** (easiest — auto-TLS):

```caddyfile
yata.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

**nginx**:

```nginx
server {
    listen 443 ssl http2;
    server_name yata.example.com;

    ssl_certificate     /etc/letsencrypt/live/yata.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yata.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
```

With a proxy in place, bind the Rust server to localhost by setting `YATA_PORT=3000` and using firewall rules to block :3000 from the outside:

```sh
sudo ufw allow 443/tcp
sudo ufw deny 3000/tcp
```

## 7. Point the iOS app at it

On the iPhone:

1. Settings → **Client** mode
2. **Server URL**: `https://yata.example.com`
3. **Username** / **Password**: the credentials you created via CLI
4. Tap **Authenticate**. Initial sync runs; you're live.

## Health check

```sh
curl -s https://yata.example.com/health
# → {"status":"ok","version":"1.0.0"}
```

## Backups

The database is a single SQLite file at `YATA_DB_PATH`. Hot-backup it safely with:

```sh
sqlite3 /var/lib/yata/yata.db ".backup '/var/backups/yata-$(date +%F).db'"
```

Script this under cron or a systemd timer.

## Upgrades

```sh
cd ~/yata && git pull && cd yata_backend && cargo build --release
sudo systemctl stop yata
sudo install -m 0755 target/release/yata_backend /usr/local/bin/yata_backend
sudo systemctl start yata
```

Migrations run automatically on startup (`sqlx::migrate!` embedded at compile time).

## Troubleshooting

- **`YATA_JWT_SECRET must be set`** — the env file wasn't loaded; check `EnvironmentFile=` path and file mode (must be readable by `yata`).
- **`no such table: users`** — DB file is from a pre-multi-tenant build. Wipe it (`rm yata.db`) and re-create users; schema migration is destructive.
- **iOS app: "Unreachable"** — check firewall, `curl` the `/health` endpoint from the phone's network, verify TLS cert is trusted.
- **`401` on every login** — wrong `YATA_JWT_SECRET` (tokens from before the restart are invalid), or the user genuinely has the wrong password.
