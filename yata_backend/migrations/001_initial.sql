-- Multi-tenant YATA schema. Every mutable entity is scoped by user_id.

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY NOT NULL,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

CREATE TABLE IF NOT EXISTS todo_items (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    is_done INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    reminder_date TEXT,
    created_at TEXT NOT NULL,
    completed_at TEXT,
    scheduled_date TEXT NOT NULL,
    source_repeating_id TEXT,
    source_repeating_rule_name TEXT,
    reschedule_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_todo_items_user_scheduled ON todo_items(user_id, scheduled_date);
CREATE INDEX IF NOT EXISTS idx_todo_items_user_updated ON todo_items(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_todo_items_user_done ON todo_items(user_id, is_done);
CREATE INDEX IF NOT EXISTS idx_todo_items_source_repeating_id ON todo_items(source_repeating_id);

CREATE TABLE IF NOT EXISTS repeating_items (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    frequency INTEGER NOT NULL DEFAULT 0,
    scheduled_time TEXT NOT NULL,
    scheduled_day_of_week INTEGER,
    scheduled_day_of_month INTEGER,
    scheduled_month INTEGER,
    sort_order INTEGER NOT NULL DEFAULT 0,
    default_urgency INTEGER NOT NULL DEFAULT 2,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_repeating_items_user ON repeating_items(user_id);
CREATE INDEX IF NOT EXISTS idx_repeating_items_user_updated ON repeating_items(user_id, updated_at);

CREATE TABLE IF NOT EXISTS deletion_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    deleted_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_deletion_log_user_type_deleted ON deletion_log(user_id, entity_type, deleted_at);
CREATE INDEX IF NOT EXISTS idx_deletion_log_deleted_at ON deletion_log(deleted_at);
