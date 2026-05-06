use std::str::FromStr;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous,
};

/// Build the canonical [`SqliteConnectOptions`] for a YATA database
/// connection. Used by both the production pool and any test helper
/// that wants real-on-disk semantics — keeping them in one place stops
/// production and tests from drifting on pragmas.
///
/// The pragmas chosen and why:
///
/// - **`journal_mode = WAL`** — writers don't block readers. Critical
///   under any concurrency (two devices, or a `/sync` pull racing a
///   write). WAL is only meaningful for on-disk DBs; an in-memory
///   `:memory:` URL has no journal at all and silently degrades to
///   MEMORY mode if asked for WAL, so we skip it for that path.
/// - **`synchronous = NORMAL`** — the WAL-mode counterpart to FULL.
///   Loses at most the last fsync window on power failure (not on
///   crashes). Acceptable for a personal todo app and ~3-10x faster
///   than FULL.
/// - **`busy_timeout = 5s`** — when SQLite hits a locking conflict
///   it busy-waits up to 5 seconds before returning SQLITE_BUSY.
///   Prevents transient timeouts when WAL checkpoints overlap a write.
/// - **`temp_store = memory`** — temporary tables and indexes go in
///   RAM rather than on disk. Negligible memory cost; meaningful
///   speedup for stats / sync queries.
/// - **`foreign_keys = ON`** — SQLite defaults this OFF per
///   connection; without it the `ON DELETE CASCADE` on `user_id`
///   silently no-ops, leaving orphaned rows when a user is deleted.
pub fn pool_options(db_path: &str) -> SqliteConnectOptions {
    let url = format!("sqlite:{db_path}?mode=rwc");
    let mut opts = SqliteConnectOptions::from_str(&url)
        .expect("invalid sqlite connect options")
        .foreign_keys(true)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5))
        .pragma("temp_store", "memory");

    // WAL only for on-disk databases. `:memory:` has no journal at
    // all, so asking for WAL there is a no-op at best and confusing
    // at worst.
    if db_path != ":memory:" {
        opts = opts.journal_mode(SqliteJournalMode::Wal);
    }

    opts
}

/// Open the production SQLite pool against `db_path` and run any
/// pending migrations. The path is created if missing (the
/// `?mode=rwc` query in `pool_options`).
pub async fn create_pool(db_path: &str) -> SqlitePool {
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(pool_options(db_path))
        .await
        .expect("Failed to connect to database");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("Failed to run migrations");

    pool
}
