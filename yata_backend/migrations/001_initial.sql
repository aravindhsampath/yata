CREATE TABLE IF NOT EXISTS todo_items (
    id TEXT PRIMARY KEY NOT NULL,
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

CREATE INDEX IF NOT EXISTS idx_todo_items_scheduled_date ON todo_items(scheduled_date);
CREATE INDEX IF NOT EXISTS idx_todo_items_source_repeating_id ON todo_items(source_repeating_id);
CREATE INDEX IF NOT EXISTS idx_todo_items_updated_at ON todo_items(updated_at);
CREATE INDEX IF NOT EXISTS idx_todo_items_is_done ON todo_items(is_done);

CREATE TABLE IF NOT EXISTS repeating_items (
    id TEXT PRIMARY KEY NOT NULL,
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

CREATE TABLE IF NOT EXISTS deletion_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    deleted_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_deletion_log_deleted_at ON deletion_log(deleted_at);
CREATE INDEX IF NOT EXISTS idx_deletion_log_entity_type ON deletion_log(entity_type);
