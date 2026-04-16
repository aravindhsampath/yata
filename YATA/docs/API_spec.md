# YATA API Specification

**Version:** 2.0
**Transport:** HTTPS (enforced in production)
**Format:** JSON
**Auth:** Bearer token (JWT, per-user)

---

## Conventions

- All timestamps are ISO 8601 with timezone: `2026-04-05T14:30:00Z`
- All dates (no time component) are `YYYY-MM-DD`: `2026-04-05`
- UUIDs are lowercase hyphenated: `550e8400-e29b-41d4-a716-446655440000`
- Field names are `snake_case`
- Every mutable entity carries `updated_at` (server-authoritative, used for conflict detection)
- Successful responses: 200 (body), 201 (created), 204 (no content)
- Errors: 400, 401, 404, 409, 422, 500

### Multi-tenancy

The server is **multi-tenant**: every TodoItem, RepeatingItem, and deletion_log row is scoped to a `user_id` derived from the caller's bearer token. Entities belonging to one user are invisible to every other user. A request that references an id owned by another user receives `404 Not Found` — the server never reveals the existence of cross-tenant data. `user_id` is **never** part of request or response payloads; it is entirely managed server-side via the JWT.

---

## Authentication

The server is multi-tenant. Each user has a `username` + `password`. There is **no public registration endpoint** — accounts are provisioned by the server operator via the CLI (see [User provisioning](#user-provisioning)). Clients log in with their credentials and receive a JWT to use for subsequent requests.

### `POST /auth/token`

Exchange username + password for a session token.

**Request:**
```json
{
  "username": "alice",
  "password": "hunter2"
}
```

**Response (200):**
```json
{
  "token": "eyJhbGciOi...",
  "expires_at": "2026-05-05T00:00:00Z"
}
```

**401 Unauthorized:** returned for both wrong password and unknown username. The server performs a dummy argon2 verify on the unknown-user path so response timing is constant — username enumeration via timing is not possible.

All subsequent requests include: `Authorization: Bearer <token>`. Token lifetime is 30 days. A 401 on any protected endpoint means the token is invalid or expired; the client must prompt the user to re-authenticate.

### User provisioning

The `yata_backend` binary doubles as an admin CLI. The server operator runs (on the host):

```sh
yata_backend create-user alice        # prompts for password twice (min 8 chars)
yata_backend list-users               # id, username, created_at
yata_backend reset-password alice     # prompts for new password
yata_backend delete-user alice        # cascades: removes all of alice's data
```

Passwords are hashed with Argon2id and stored in the `users` table. The JWT signing key is a separate server-side secret (`YATA_JWT_SECRET` env var) that is never exposed over the API.

---

## Error Format

Every error response follows this shape:

```json
{
  "error": {
    "code": "conflict",
    "message": "Item was modified on server since your last sync",
    "server_version": { ... }
  }
}
```

| Code | HTTP | Meaning |
|------|------|---------|
| `unauthorized` | 401 | Token invalid/expired |
| `not_found` | 404 | Entity does not exist |
| `conflict` | 409 | Version mismatch — `server_version` field contains current state |
| `validation_error` | 422 | Bad input — `details` field lists invalid fields |
| `server_error` | 500 | Unexpected failure |

---

## Data Models

### TodoItem

```json
{
  "id": "uuid",
  "title": "string",
  "priority": 0,
  "is_done": false,
  "sort_order": 0,
  "reminder_date": "2026-04-05T09:00:00Z",
  "created_at": "2026-04-05T08:00:00Z",
  "completed_at": null,
  "scheduled_date": "2026-04-05",
  "source_repeating_id": null,
  "source_repeating_rule_name": null,
  "reschedule_count": 0,
  "updated_at": "2026-04-05T08:00:00Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | Client-generated, sent on creation |
| `title` | string | Required, non-empty |
| `priority` | int | 0=low (Later), 1=medium (Soon), 2=high (Now) |
| `is_done` | bool | |
| `sort_order` | int | Position within priority lane for a given date |
| `reminder_date` | ISO8601 or null | Full datetime with timezone |
| `created_at` | ISO8601 | Set by server on creation |
| `completed_at` | ISO8601 or null | Set when `is_done` transitions to true |
| `scheduled_date` | date string | The day this item appears on (YYYY-MM-DD) |
| `source_repeating_id` | UUID or null | Links to parent RepeatingItem |
| `source_repeating_rule_name` | string or null | Denormalized for display |
| `reschedule_count` | int | Times this item has been pushed forward |
| `updated_at` | ISO8601 | Server-authoritative, updated on every mutation |

### RepeatingItem

```json
{
  "id": "uuid",
  "title": "string",
  "frequency": 0,
  "scheduled_time": "09:00:00",
  "scheduled_day_of_week": null,
  "scheduled_day_of_month": null,
  "scheduled_month": null,
  "sort_order": 0,
  "default_urgency": 2,
  "updated_at": "2026-04-05T08:00:00Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | Client-generated |
| `title` | string | Required |
| `frequency` | int | 0=daily, 1=everyWorkday, 2=weekly, 3=monthly, 4=yearly |
| `scheduled_time` | time string | `HH:MM:SS` — time of day for the occurrence |
| `scheduled_day_of_week` | int or null | 1=Sun, 7=Sat. Required for weekly. |
| `scheduled_day_of_month` | int or null | 1-28. Required for monthly/yearly. |
| `scheduled_month` | int or null | 1-12. Required for yearly. |
| `sort_order` | int | Display order in the repeating rules list |
| `default_urgency` | int | Priority assigned to materialized occurrences |
| `updated_at` | ISO8601 | Server-authoritative |

---

## Endpoints

### Todo Items

#### `GET /items`

Fetch items for a date and optional priority filter.

**Query params:**
| Param | Required | Type | Notes |
|-------|----------|------|-------|
| `date` | yes | YYYY-MM-DD | Scheduled date |
| `priority` | no | int | Filter to single priority |

**Response (200):**
```json
{
  "items": [ TodoItem, ... ]
}
```

Items are sorted by `sort_order` ascending. If no `priority` filter, returns all priorities for that date.

---

#### `GET /items/done`

Fetch recently completed items.

**Query params:**
| Param | Required | Default |
|-------|----------|---------|
| `limit` | no | 25 |
| `offset` | no | 0 |

**Response (200):**
```json
{
  "items": [ TodoItem, ... ],
  "total": 142
}
```

Sorted by `completed_at` descending.

---

#### `POST /items`

Create a new item.

**Request:**
```json
{
  "id": "uuid",
  "title": "Call roof guy",
  "priority": 2,
  "scheduled_date": "2026-04-05",
  "reminder_date": "2026-04-05T14:00:00Z",
  "sort_order": 3,
  "source_repeating_id": null,
  "source_repeating_rule_name": null
}
```

Client generates the UUID. Server sets `created_at`, `updated_at`, `is_done=false`, `completed_at=null`, `reschedule_count=0`.

**Response (201):** Full TodoItem with server-set fields.

---

#### `PUT /items/:id`

Update an item. Send full item state (not a patch).

**Request:**
```json
{
  "title": "Call Stefan about roof",
  "priority": 2,
  "is_done": false,
  "sort_order": 3,
  "reminder_date": "2026-04-05T14:00:00Z",
  "scheduled_date": "2026-04-05",
  "reschedule_count": 0,
  "updated_at": "2026-04-05T08:00:00Z"
}
```

**Conflict detection:** Client sends its `updated_at`. Server compares: if server's `updated_at` > client's, returns 409 with `server_version`.

**Response (200):** Updated TodoItem.
**Response (409):** Conflict — body includes `server_version` with current server state.

---

#### `DELETE /items/:id`

**Response (204):** No content.
**Response (404):** Already deleted (idempotent — client can ignore).

---

### Batch Operations

These exist as dedicated endpoints because they involve business logic beyond simple CRUD.

#### `POST /items/reorder`

Reorder items within a priority lane for a date.

**Request:**
```json
{
  "date": "2026-04-05",
  "priority": 2,
  "ids": ["uuid-1", "uuid-2", "uuid-3"]
}
```

Server sets `sort_order` to 0, 1, 2, ... matching the array order.

**Response (200):**
```json
{
  "items": [ TodoItem, ... ]
}
```

---

#### `POST /items/:id/move`

Move an item to a different priority.

**Request:**
```json
{
  "to_priority": 1,
  "at_index": 2
}
```

Server changes priority, inserts at the given index, adjusts sort_order of other items.

**Response (200):** Updated TodoItem.

---

#### `POST /items/:id/done`

Mark item as done. Sets `is_done=true`, `completed_at=now`.

**Response (200):** Updated TodoItem.

---

#### `POST /items/:id/undone`

Mark item as not done. Sets `is_done=false`, `completed_at=null`.

**Request:**
```json
{
  "scheduled_date": "2026-04-05"
}
```

The `scheduled_date` is needed because the item returns to a priority lane on a specific date.

**Response (200):** Updated TodoItem.

---

#### `POST /items/:id/reschedule`

Move item to a different date.

**Request:**
```json
{
  "to_date": "2026-04-06",
  "reset_count": false
}
```

If `reset_count=true`: `reschedule_count=0`. Otherwise: `reschedule_count += 1`.

**Response (200):** Updated TodoItem.

---

### Server-Side Operations

These operations involve cross-item logic. The server executes them — clients trigger them.

#### `POST /operations/rollover`

Roll over overdue items to a target date.

**Request:**
```json
{
  "to_date": "2026-04-05"
}
```

Server finds all non-done items with `scheduled_date < to_date`, moves them to `to_date`, increments each item's `reschedule_count`.

**Response (200):**
```json
{
  "rolled_over_count": 5
}
```

---

#### `POST /operations/materialize`

Materialize repeating items for a date range.

**Request:**
```json
{
  "start_date": "2026-04-05",
  "end_date": "2026-04-11"
}
```

Server computes firing dates for all repeating rules within the range, creates TodoItem occurrences where they don't already exist (dedup by `source_repeating_id` + `scheduled_date`).

**Response (200):**
```json
{
  "created_count": 12
}
```

---

### Analytics

#### `GET /stats/counts`

Task counts by priority for multiple dates. Powers the week strip dot ring.

**Query params:**
| Param | Required | Notes |
|-------|----------|-------|
| `dates` | yes | Comma-separated YYYY-MM-DD |

**Response (200):**
```json
{
  "counts": {
    "2026-04-05": { "0": 2, "1": 3, "2": 1 },
    "2026-04-06": { "0": 0, "1": 1, "2": 4 }
  }
}
```

Keys are priority raw values (0, 1, 2). Values are non-done item counts.

---

#### `GET /stats/done-count`

**Query params:** `date=YYYY-MM-DD`

**Response (200):**
```json
{
  "count": 7
}
```

---

### Repeating Items

#### `GET /repeating`

**Response (200):**
```json
{
  "items": [ RepeatingItem, ... ]
}
```

Sorted by `sort_order`.

---

#### `POST /repeating`

**Request:**
```json
{
  "id": "uuid",
  "title": "Daily standup",
  "frequency": 0,
  "scheduled_time": "09:00:00",
  "scheduled_day_of_week": null,
  "scheduled_day_of_month": null,
  "scheduled_month": null,
  "sort_order": 0,
  "default_urgency": 2
}
```

**Response (201):** Full RepeatingItem.

---

#### `PUT /repeating/:id`

Full update. Same conflict detection as TodoItem (send `updated_at`, server returns 409 on mismatch).

**Response (200):** Updated RepeatingItem.

---

#### `DELETE /repeating/:id`

**Cascade:** Server deletes all undone TodoItem occurrences linked via `source_repeating_id`. Done occurrences are preserved (they're historical records).

**Response (204):** No content.

---

### Sync

#### `GET /sync`

Delta sync — fetch everything changed since a timestamp.

**Query params:**
| Param | Required | Notes |
|-------|----------|-------|
| `since` | yes | ISO8601 timestamp |

**Response (200):**
```json
{
  "items": {
    "upserted": [ TodoItem, ... ],
    "deleted": [ "uuid-1", "uuid-2" ]
  },
  "repeating": {
    "upserted": [ RepeatingItem, ... ],
    "deleted": [ "uuid-3" ]
  },
  "server_time": "2026-04-05T14:30:00Z"
}
```

- `upserted`: items created or modified since `since` — client overwrites local copies
- `deleted`: IDs of items deleted since `since` — client removes local copies
- `server_time`: use as the `since` value for the next sync call

The server must retain soft-deleted records (or a deletion log) long enough for clients to sync. Recommended: 30 days.

---

### Health

#### `GET /health`

No auth required. Used by client to check connectivity.

**Response (200):**
```json
{
  "status": "ok",
  "version": "1.0.0"
}
```
