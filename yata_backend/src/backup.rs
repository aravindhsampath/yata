//! Local-filesystem SQLite backups.
//!
//! Uses `VACUUM INTO` rather than copying the file. Three reasons:
//!
//! 1. **WAL safety.** A naive `cp yata.db /backup/yata.db` skips the
//!    `-wal` and `-shm` sidecars and produces a torn snapshot any
//!    time a transaction is mid-flight. `VACUUM INTO` is the
//!    SQLite-blessed way to take a consistent snapshot from a live
//!    database without quiescing writers.
//! 2. **Single self-contained file.** The output has no sidecars and
//!    is restorable just by copying it back into place.
//! 3. **Compaction.** `VACUUM INTO` drops free pages, so backups
//!    are smaller than the source. Useful for long-running
//!    deployments where `done_items` accumulate before retention
//!    policies run.
//!
//! On the rotation policy: simple "keep N newest *.db files in this
//!  directory" is enough for the personal-scale operator. Anything
//! more (compression, off-site copy) should layer on top — e.g.
//! follow this with `restic` or `rclone` if you want B2 / S3.

use std::io;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::SystemTime;

use sqlx::ConnectOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};

#[derive(Debug)]
pub enum BackupError {
    Connect(sqlx::Error),
    Io(io::Error),
    SourceMissing(PathBuf),
    OutputExists(PathBuf),
}

impl std::fmt::Display for BackupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connect(e) => write!(f, "sqlite: {e}"),
            Self::Io(e) => write!(f, "filesystem: {e}"),
            Self::SourceMissing(p) => {
                write!(f, "source database '{}' does not exist", p.display())
            }
            Self::OutputExists(p) => write!(
                f,
                "refusing to overwrite existing backup at '{}'",
                p.display()
            ),
        }
    }
}

impl std::error::Error for BackupError {}

impl From<sqlx::Error> for BackupError {
    fn from(e: sqlx::Error) -> Self {
        Self::Connect(e)
    }
}

impl From<io::Error> for BackupError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// Create a consistent point-in-time copy of `source_db_path` at
/// `output_path`. Returns the size of the resulting file in bytes.
///
/// Refuses to overwrite an existing output file — callers must name
/// new backups uniquely (timestamp etc.).
pub async fn create_backup(
    source_db_path: &str,
    output_path: &Path,
) -> Result<u64, BackupError> {
    let source = Path::new(source_db_path);
    if source_db_path != ":memory:" && !source.exists() {
        return Err(BackupError::SourceMissing(source.to_path_buf()));
    }
    if output_path.exists() {
        return Err(BackupError::OutputExists(output_path.to_path_buf()));
    }
    if let Some(parent) = output_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }

    // Open source read-only. RW would touch the WAL header and could
    // race with the live process. The `mode=ro` + `read_only(true)`
    // belt-and-suspenders is intentional.
    let opts = SqliteConnectOptions::from_str(&format!("sqlite:{source_db_path}?mode=ro"))
        .map_err(BackupError::Connect)?
        .read_only(true);
    let mut conn: SqliteConnection = opts.connect().await?;

    // VACUUM INTO doesn't accept a bound parameter for the path; the
    // path is part of SQL grammar. Escape single quotes by doubling
    // them — safest stringification we can do here.
    let escaped = output_path.to_string_lossy().replace('\'', "''");
    sqlx::query(&format!("VACUUM INTO '{escaped}'"))
        .execute(&mut conn)
        .await?;

    let metadata = std::fs::metadata(output_path)?;
    Ok(metadata.len())
}

/// Keep only the `keep` newest `*.db` files in `backup_dir` (by
/// mtime), deleting the rest. Returns the number of files actually
/// deleted.
///
/// The `*.db` filter prevents accidental deletion of unrelated files
/// (a stray README, an `.sqlite-wal`, a backup of a different DB).
/// Files in subdirectories are never touched.
///
/// `keep == 0` is treated as a no-op rather than "delete everything"
/// — the caller almost certainly didn't mean to nuke their entire
/// backup set with a single misconfigured env var.
pub fn rotate(backup_dir: &Path, keep: usize) -> Result<usize, BackupError> {
    if keep == 0 {
        return Ok(0);
    }
    if !backup_dir.exists() {
        return Ok(0);
    }

    let mut entries: Vec<(SystemTime, PathBuf)> = std::fs::read_dir(backup_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|s| s.to_str())
                .is_some_and(|s| s == "db")
        })
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            let mtime = m.modified().ok()?;
            Some((mtime, e.path()))
        })
        .collect();

    if entries.len() <= keep {
        return Ok(0);
    }

    entries.sort_by(|a, b| b.0.cmp(&a.0)); // newest first
    let mut deleted = 0;
    for (_, path) in &entries[keep..] {
        if std::fs::remove_file(path).is_ok() {
            deleted += 1;
        }
    }
    Ok(deleted)
}

/// Convenience: build the conventional backup filename for a given
/// instant. Format: `yata-YYYYMMDD-HHMMSS.db` in UTC. Predictable,
/// sortable lexicographically, and matches the rotation glob.
pub fn default_filename(now: chrono::DateTime<chrono::Utc>) -> String {
    format!("yata-{}.db", now.format("%Y%m%d-%H%M%S"))
}
