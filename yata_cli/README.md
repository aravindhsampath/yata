# yata — CLI for the YATA todo backend

A command-line client that speaks the same REST API the iOS app does. Built for two audiences:

1. **You, from a terminal.** `yata add "Buy milk" --urgency green`.
2. **LLMs as tool users.** JSON on stdout by default, a single-shot `yata schema` for capability discovery, stable error codes, and title-prefix matching so "done the milk thing" works.

## Install

From the repo root:

```sh
cargo install --path yata_cli
# binary lands at ~/.cargo/bin/yata
```

Or copy `target/release/yata` anywhere on `$PATH`.

## Quick start

```sh
yata login --url https://yata.example.com --username alice
# password prompt is hidden

yata add "Buy milk" --urgency green
yata list --pretty
yata done "buy milk"
yata stats
```

## For LLMs

**Start every session with `yata schema`.** It returns ~400 tokens describing every command, every flag, the urgency/date vocab, env-var overrides, error codes, and exit-code conventions. Use `yata schema --json` (~240 tokens) if you want a structured form.

Rules the CLI enforces to make your job easier:
- **Default output is compact JSON on stdout.** No need to pass `--json` — pass `--pretty` only when a human is reading.
- **Errors are JSON on stderr** with a stable `code` field. Codes: `missing_config`, `no_match`, `ambiguous_match`, `api_error`, `network_error`, `unauthorized`, `validation_error`, `not_found`, `conflict`.
- **`<q>` arguments** (to `done`, `undo`, `delete`, `reschedule`, `move`) accept either a UUID or a case-insensitive title substring. If the substring matches zero items you get `no_match`; if it matches >1, you get `ambiguous_match` with a `matches` array — pick one and retry with the UUID.
- **Urgency synonyms**: `green`≡`high`, `yellow`≡`medium`, `red`≡`low`. Pick whichever reads naturally.
- **Date synonyms**: `today`, `tomorrow`, `yesterday`, `next-week`, or an ISO `YYYY-MM-DD`.

### Invocation patterns

```sh
# Discovery (do this once per session)
yata schema

# Auth is cached. For sandboxed / container use, pass via env:
YATA_URL=https://yata.example.com YATA_TOKEN=eyJ… yata list

# Add, list, resolve by title, complete:
yata add "Ship the demo" --urgency green --date today --reminder 2026-04-18T09:00:00Z
yata list --date today
yata done "ship the demo"

# Bulk-style chaining via jq:
yata list --date today | jq -r '.items[] | select(.priority==2) | .id' \
  | xargs -I{} yata done {}

# Anything the curated commands don't cover:
yata raw POST /operations/rollover --body '{"to_date":"2026-04-18"}'
```

## Commands reference

See `yata <command> --help`, or the single-shot `yata schema` which is kept deliberately dense. A quick map:

| Command | Purpose |
|---|---|
| `login` / `logout` / `status` | Auth + health |
| `add <title>` | Create a todo |
| `list` | Read todos (by date, urgency, or done list) |
| `done <q>` / `undo <q>` / `delete <q>` | State changes |
| `reschedule <q>` / `move <q>` | Rearrange |
| `stats` | Priority counts + done total for a date |
| `repeating list` | View repeating rules |
| `raw <METHOD> <PATH>` | Escape hatch for anything else |
| `schema` | LLM capability discovery |

## Auth + config

Config lives at `~/.config/yata/config.json` (mode `0600`) and stores `{url, username, token, expires_at}`. Tokens expire after 30 days; on 401 the CLI tells you to re-login.

For non-interactive use (CI, containers, LLM sandboxes), any of these env vars override the on-disk config:

| Env | Effect |
|---|---|
| `YATA_URL` | Server base URL |
| `YATA_USERNAME` | Username (informational) |
| `YATA_TOKEN` | Pre-minted JWT — skips the `/auth/token` roundtrip |
| `YATA_PASSWORD` | Used by `yata login --username …` when `--password` is omitted |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | User error (bad args, no match, ambiguous match, validation) |
| 2 | API error (4xx/5xx that isn't classified as user) |
| 3 | Network or config error (no auth cached, can't reach server) |

## Pretty mode

Pass `--pretty` on any command to get a compact human rendering instead of JSON:

```
✓ 🟢  f07bfe88  Buy milk  (2026-04-17)
  🟡  da0c1d77  Review yata PR  (2026-04-18)
  🔴  9aedc89e  Read ADHD book chapter 3  (2026-04-17)
```
