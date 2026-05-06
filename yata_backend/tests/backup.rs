// Backup module integration tests.
//
// Verifies the three properties an operator actually cares about:
//
// 1. The backup file passes SQLite's `PRAGMA integrity_check`. If the
//    snapshot is corrupt or torn, this fires.
// 2. Row counts in the backup match the source. If the snapshot is
//    consistent but stale (e.g. taken before a write committed), this
//    fires.
// 3. Rotation keeps the N newest files by mtime. The CLI defaults to
//    14; this test covers the boundary.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use sqlx::Row;
use sqlx::sqlite::SqlitePoolOptions;
use yata_backend::backup;
use yata_backend::db;

fn unique_temp_dir(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "yata-backup-test-{label}-{}-{}",
        std::process::id(),
        nanos
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn cleanup_dir(dir: &Path) {
    let _ = std::fs::remove_dir_all(dir);
}

/// Create a SQLite DB at `path`, run migrations, and seed `n` users
/// so we have something concrete to count against.
async fn seed_db(path: &Path, n_users: usize) {
    let path_str = path.to_str().unwrap();
    let pool = db::create_pool(path_str).await;
    for i in 0..n_users {
        let id = format!("user-{i:04}");
        let username = format!("user{i}");
        sqlx::query(
            "INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)",
        )
        .bind(&id)
        .bind(&username)
        .bind("dummy-hash")
        .bind("2026-04-23T00:00:00Z")
        .execute(&pool)
        .await
        .expect("seed users");
    }
    pool.close().await;
}

#[tokio::test]
async fn backup_file_passes_integrity_check() {
    let dir = unique_temp_dir("integrity");
    let source = dir.join("source.db");
    let backup_path = dir.join("snap.db");

    seed_db(&source, 3).await;

    let bytes = backup::create_backup(source.to_str().unwrap(), &backup_path)
        .await
        .expect("backup");
    assert!(bytes > 0, "backup file should be non-empty");
    assert!(backup_path.exists(), "backup file should exist on disk");

    // Reopen the backup and run integrity_check. Must report "ok".
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect(&format!("sqlite:{}?mode=ro", backup_path.display()))
        .await
        .expect("open backup");
    let row = sqlx::query("PRAGMA integrity_check")
        .fetch_one(&pool)
        .await
        .expect("integrity check");
    let result: String = row.get(0);
    assert_eq!(result, "ok", "backup integrity_check failed: {result}");
    pool.close().await;

    cleanup_dir(&dir);
}

#[tokio::test]
async fn backup_preserves_row_counts() {
    let dir = unique_temp_dir("rows");
    let source = dir.join("source.db");
    let backup_path = dir.join("snap.db");

    let n = 7;
    seed_db(&source, n).await;

    backup::create_backup(source.to_str().unwrap(), &backup_path)
        .await
        .expect("backup");

    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect(&format!("sqlite:{}?mode=ro", backup_path.display()))
        .await
        .expect("open backup");
    let row = sqlx::query("SELECT COUNT(*) FROM users")
        .fetch_one(&pool)
        .await
        .expect("count users");
    let count: i64 = row.get(0);
    assert_eq!(
        count, n as i64,
        "expected {n} users in backup, found {count}"
    );
    pool.close().await;

    cleanup_dir(&dir);
}

#[tokio::test]
async fn backup_refuses_to_overwrite_existing_file() {
    let dir = unique_temp_dir("overwrite");
    let source = dir.join("source.db");
    let backup_path = dir.join("existing.db");

    seed_db(&source, 1).await;
    std::fs::write(&backup_path, b"i was here first").expect("pre-seed file");

    let err = backup::create_backup(source.to_str().unwrap(), &backup_path)
        .await
        .expect_err("must error");
    match err {
        backup::BackupError::OutputExists(_) => {}
        other => panic!("expected OutputExists, got {other:?}"),
    }

    cleanup_dir(&dir);
}

#[tokio::test]
async fn backup_errors_when_source_missing() {
    let dir = unique_temp_dir("missing");
    let source = dir.join("does-not-exist.db");
    let backup_path = dir.join("snap.db");

    let err = backup::create_backup(source.to_str().unwrap(), &backup_path)
        .await
        .expect_err("must error");
    match err {
        backup::BackupError::SourceMissing(_) => {}
        other => panic!("expected SourceMissing, got {other:?}"),
    }

    cleanup_dir(&dir);
}

/// Set the mtime of `path` to `n` seconds after `base` so we get
/// reproducible ordering without relying on SystemTime::now().
fn set_mtime(path: &Path, base: SystemTime, offset_secs: u64) {
    let target = base + Duration::from_secs(offset_secs);
    let ftime = filetime::FileTime::from_system_time(target);
    filetime::set_file_mtime(path, ftime).expect("set_file_mtime");
}

#[tokio::test]
async fn rotation_keeps_only_n_newest_by_mtime() {
    let dir = unique_temp_dir("rotation");

    // Create five "backup" files with deterministic mtimes so the
    // sort order is unambiguous.
    let base = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    let names = ["a.db", "b.db", "c.db", "d.db", "e.db"];
    for (i, name) in names.iter().enumerate() {
        let p = dir.join(name);
        std::fs::write(&p, format!("file {i}")).expect("write");
        set_mtime(&p, base, i as u64 * 10); // a oldest, e newest
    }

    // A non-`.db` file must not be touched by rotation.
    let readme = dir.join("README.md");
    std::fs::write(&readme, "do not delete").expect("write readme");

    let deleted = backup::rotate(&dir, 3).expect("rotate");
    assert_eq!(deleted, 2, "expected to delete 2 oldest of 5");

    // Confirm the 3 newest survived.
    for name in &names[2..] {
        assert!(dir.join(name).exists(), "{name} should have survived rotation");
    }
    for name in &names[..2] {
        assert!(!dir.join(name).exists(), "{name} should have been deleted");
    }
    assert!(readme.exists(), "non-.db files must be untouched");

    cleanup_dir(&dir);
}

#[tokio::test]
async fn rotation_with_keep_zero_is_noop() {
    let dir = unique_temp_dir("keep-zero");
    std::fs::write(dir.join("a.db"), "x").unwrap();
    std::fs::write(dir.join("b.db"), "y").unwrap();

    let deleted = backup::rotate(&dir, 0).expect("rotate");
    assert_eq!(deleted, 0, "keep=0 must be a no-op (defensive)");
    assert!(dir.join("a.db").exists());
    assert!(dir.join("b.db").exists());

    cleanup_dir(&dir);
}

#[tokio::test]
async fn rotation_skips_when_under_keep_count() {
    let dir = unique_temp_dir("under");
    std::fs::write(dir.join("only.db"), "x").unwrap();

    let deleted = backup::rotate(&dir, 14).expect("rotate");
    assert_eq!(deleted, 0);
    assert!(dir.join("only.db").exists());

    cleanup_dir(&dir);
}

/// Convenience smoke: the default filename is sortable and matches
/// the rotation glob (`*.db`).
#[tokio::test]
async fn default_filename_is_sortable_db_file() {
    let now = chrono::DateTime::parse_from_rfc3339("2026-04-23T11:22:33+00:00")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let name = backup::default_filename(now);
    assert_eq!(name, "yata-20260423-112233.db");
    assert!(name.ends_with(".db"));
}
