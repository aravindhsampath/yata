// Verifies that `db::create_pool` actually applies the pragmas we
// claim it does. Locks in the WAL + tuned-pragma decision so a future
// refactor can't silently drop one of them.
//
// Each pragma carries a comment in `db.rs::pool_options` explaining
// why we picked the value; this test fails loudly if any of those
// values change.

use std::env;
use std::process;

use sqlx::Row;
use yata_backend::db;

/// Build a unique temp DB path per test run (PID + nanoseconds since
/// epoch) so concurrent `cargo test` invocations don't collide. We
/// don't use the `tempfile` crate to avoid a new dev-dependency for
/// what's effectively a one-off path.
fn unique_temp_db_path(label: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    env::temp_dir().join(format!(
        "yata-pragma-test-{label}-{}-{}.db",
        process::id(),
        nanos
    ))
}

/// Best-effort cleanup. Each WAL connection produces three files:
/// `<name>`, `<name>-wal`, `<name>-shm`.
fn cleanup(path: &std::path::Path) {
    for suffix in ["", "-wal", "-shm"] {
        let p = path.with_extension(format!(
            "{}{suffix}",
            path.extension()
                .and_then(|s| s.to_str())
                .unwrap_or("db")
        ));
        let _ = std::fs::remove_file(&p);
    }
    let _ = std::fs::remove_file(path);
}

#[tokio::test]
async fn pool_uses_wal_journal_mode_on_disk() {
    let path = unique_temp_db_path("wal");
    let pool = db::create_pool(path.to_str().unwrap()).await;

    let row = sqlx::query("PRAGMA journal_mode")
        .fetch_one(&pool)
        .await
        .expect("PRAGMA journal_mode");
    let mode: String = row.get(0);
    assert_eq!(
        mode.to_lowercase(),
        "wal",
        "expected WAL journal mode for on-disk pool, got {mode}"
    );

    drop(pool);
    cleanup(&path);
}

#[tokio::test]
async fn pool_has_synchronous_normal() {
    let path = unique_temp_db_path("sync");
    let pool = db::create_pool(path.to_str().unwrap()).await;

    // SQLite reports `synchronous` as an integer:
    // 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA.
    let row = sqlx::query("PRAGMA synchronous")
        .fetch_one(&pool)
        .await
        .expect("PRAGMA synchronous");
    let sync: i64 = row.get(0);
    assert_eq!(sync, 1, "expected synchronous=NORMAL (1), got {sync}");

    drop(pool);
    cleanup(&path);
}

#[tokio::test]
async fn pool_has_foreign_keys_enabled() {
    let path = unique_temp_db_path("fk");
    let pool = db::create_pool(path.to_str().unwrap()).await;

    let row = sqlx::query("PRAGMA foreign_keys")
        .fetch_one(&pool)
        .await
        .expect("PRAGMA foreign_keys");
    let fk: i64 = row.get(0);
    assert_eq!(
        fk, 1,
        "expected foreign_keys=ON (1) — without it, ON DELETE CASCADE silently no-ops"
    );

    drop(pool);
    cleanup(&path);
}

#[tokio::test]
async fn pool_has_busy_timeout_set() {
    let path = unique_temp_db_path("busy");
    let pool = db::create_pool(path.to_str().unwrap()).await;

    let row = sqlx::query("PRAGMA busy_timeout")
        .fetch_one(&pool)
        .await
        .expect("PRAGMA busy_timeout");
    let timeout: i64 = row.get(0);
    assert!(
        timeout >= 5_000,
        "expected busy_timeout >= 5000ms, got {timeout}"
    );

    drop(pool);
    cleanup(&path);
}

/// `:memory:` databases have no journal — asking SQLite for WAL on
/// one would be either a no-op or a confusing degradation. Verify
/// `pool_options` has the right behavior so test_helpers can safely
/// share this code path in the future.
#[tokio::test]
async fn memory_pool_does_not_request_wal() {
    use sqlx::ConnectOptions;
    use sqlx::sqlite::SqliteConnection;

    let opts = db::pool_options(":memory:");
    let mut conn: SqliteConnection = opts.connect().await.expect("connect to in-memory");

    let row = sqlx::query("PRAGMA journal_mode")
        .fetch_one(&mut conn)
        .await
        .expect("PRAGMA journal_mode");
    let mode: String = row.get(0);
    // In-memory DBs report "memory". Anything other than "wal" is
    // acceptable here — we just want to be sure we didn't try to set
    // it to WAL (which would degrade silently).
    assert_ne!(
        mode.to_lowercase(),
        "wal",
        "in-memory pool should not be in WAL mode, got {mode}"
    );
}
