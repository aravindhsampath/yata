use std::path::PathBuf;

use clap::{Parser, Subcommand};
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use yata_backend::backup;
use yata_backend::config::Config;
use yata_backend::observability;
use yata_backend::password::hash_password;

#[derive(Parser)]
#[command(name = "yata_backend", version, about = "YATA self-hosted backend")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Create a new user. Prompts for the password.
    CreateUser {
        /// Unique username.
        username: String,
        /// Read the password from stdin (one line) instead of prompting on
        /// the TTY. Intended for scripted/containerized provisioning.
        #[arg(long)]
        password_stdin: bool,
    },
    /// List all users.
    ListUsers,
    /// Delete a user and all their data (cascade).
    DeleteUser {
        /// Username to remove.
        username: String,
    },
    /// Change a user's password. Prompts for the new password.
    ResetPassword {
        /// Username to update.
        username: String,
        /// Read the new password from stdin (one line) instead of prompting.
        #[arg(long)]
        password_stdin: bool,
    },
    /// Take a consistent point-in-time snapshot of the database to a
    /// local-filesystem path. Uses SQLite's `VACUUM INTO` so the live
    /// server doesn't need to be quiesced. Designed to be invoked
    /// from a cron / systemd timer; see `deployment/yata-backup.*`.
    Backup {
        /// Directory to write the backup into. Created if missing.
        #[arg(long, default_value = "/var/backups/yata")]
        output_dir: PathBuf,
        /// Number of newest backup files to retain after this run.
        /// Older files in `--output-dir` are deleted. `0` is treated
        /// as "no rotation, keep everything" — defensive against an
        /// operator typo wiping the whole backup history.
        #[arg(long, default_value_t = 14)]
        keep: usize,
    },
}

#[tokio::main]
async fn main() {
    let format = observability::init();
    tracing::info!(?format, "tracing initialized");

    let cli = Cli::parse();
    let config = Config::from_env();
    let pool = yata_backend::db::create_pool(&config.db_path).await;

    match cli.command {
        None => run_server(pool, config).await,
        Some(Command::CreateUser { username, password_stdin }) => {
            cmd_create_user(&pool, &username, password_stdin).await
        }
        Some(Command::ListUsers) => cmd_list_users(&pool).await,
        Some(Command::DeleteUser { username }) => cmd_delete_user(&pool, &username).await,
        Some(Command::ResetPassword { username, password_stdin }) => {
            cmd_reset_password(&pool, &username, password_stdin).await
        }
        Some(Command::Backup { output_dir, keep }) => {
            cmd_backup(&config.db_path, &output_dir, keep).await
        }
    }
}

async fn cmd_backup(db_path: &str, output_dir: &std::path::Path, keep: usize) {
    // Conventional name: `yata-YYYYMMDD-HHMMSS.db`. Sortable, unique
    // at second granularity, and matches the rotation `*.db` filter.
    let now = chrono::Utc::now();
    let filename = backup::default_filename(now);
    let output_path = output_dir.join(&filename);

    match backup::create_backup(db_path, &output_path).await {
        Ok(bytes) => {
            println!("backup ok: {} ({} bytes)", output_path.display(), bytes);
        }
        Err(e) => {
            eprintln!("error: backup failed: {e}");
            std::process::exit(1);
        }
    }

    match backup::rotate(output_dir, keep) {
        Ok(0) => {}
        Ok(n) => println!("rotated: removed {n} old backup(s), kept {keep} newest"),
        Err(e) => {
            // Don't fail the whole command for a rotation hiccup —
            // the new backup is on disk, which is the primary goal.
            eprintln!("warning: rotation failed: {e}");
        }
    }
}

async fn run_server(pool: SqlitePool, config: Config) {
    // Purge old deletion log entries (>30 days) on startup
    let cutoff = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
    let purged = sqlx::query("DELETE FROM deletion_log WHERE deleted_at < ?")
        .bind(&cutoff)
        .execute(&pool)
        .await;
    if let Ok(result) = purged
        && result.rows_affected() > 0
    {
        tracing::info!("purged {} old deletion log entries", result.rows_affected());
    }

    let addr = format!("0.0.0.0:{}", config.port);
    let app = yata_backend::routes::build_router(pool, config);
    tracing::info!("YATA server listening on {addr}");

    let listener = TcpListener::bind(&addr).await.expect("failed to bind");
    // `into_make_service_with_connect_info::<SocketAddr>` wires the
    // peer's address into request extensions as `ConnectInfo<SocketAddr>`.
    // Without it, `tower_governor`'s `SmartIpKeyExtractor` can't find a
    // peer IP for direct (non-proxied) requests and returns 500
    // "Unable To Extract Key!" — a smoke-test caught this just before
    // we were about to ship. Caddy hides the bug in prod by sending
    // `X-Forwarded-For`, but loopback / dev / future deployments
    // without an L7 proxy must still work.
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
    .expect("server error");
}

async fn cmd_create_user(pool: &SqlitePool, username: &str, password_stdin: bool) {
    if username.trim().is_empty() {
        eprintln!("error: username must not be empty");
        std::process::exit(1);
    }

    // Check for existing user first so we don't prompt for a password needlessly.
    let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM users WHERE username = ?")
        .bind(username)
        .fetch_optional(pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("error: db query failed: {e}");
            std::process::exit(1);
        });
    if exists.is_some() {
        eprintln!("error: user '{username}' already exists");
        std::process::exit(1);
    }

    let password = read_password(password_stdin);
    let hash = hash_password(&password).unwrap_or_else(|e| {
        eprintln!("error: password hash failed: {e:?}");
        std::process::exit(1);
    });

    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    // password_changed_at = now ensures a freshly created user can never
    // receive a token whose iat predates their account. The migration's
    // epoch default is for back-fill of existing rows; new rows should
    // always be stamped with an accurate timestamp.
    sqlx::query("INSERT INTO users (id, username, password_hash, created_at, password_changed_at) VALUES (?, ?, ?, ?, ?)")
        .bind(&id)
        .bind(username)
        .bind(&hash)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("error: insert failed: {e}");
            std::process::exit(1);
        });

    println!("created user: {username} (id={id})");
}

async fn cmd_list_users(pool: &SqlitePool) {
    let rows: Vec<(String, String, String)> =
        sqlx::query_as("SELECT id, username, created_at FROM users ORDER BY created_at ASC")
            .fetch_all(pool)
            .await
            .unwrap_or_else(|e| {
                eprintln!("error: db query failed: {e}");
                std::process::exit(1);
            });

    if rows.is_empty() {
        println!("no users");
        return;
    }

    for (id, username, created_at) in rows {
        println!("{id}  {username}  {created_at}");
    }
}

async fn cmd_delete_user(pool: &SqlitePool, username: &str) {
    let result = sqlx::query("DELETE FROM users WHERE username = ?")
        .bind(username)
        .execute(pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("error: delete failed: {e}");
            std::process::exit(1);
        });

    if result.rows_affected() == 0 {
        eprintln!("error: user '{username}' not found");
        std::process::exit(1);
    }
    println!("deleted user: {username} (cascade removed all linked items)");
}

async fn cmd_reset_password(pool: &SqlitePool, username: &str, password_stdin: bool) {
    let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM users WHERE username = ?")
        .bind(username)
        .fetch_optional(pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("error: db query failed: {e}");
            std::process::exit(1);
        });
    if exists.is_none() {
        eprintln!("error: user '{username}' not found");
        std::process::exit(1);
    }

    let password = read_password(password_stdin);
    let hash = hash_password(&password).unwrap_or_else(|e| {
        eprintln!("error: password hash failed: {e:?}");
        std::process::exit(1);
    });

    // Also bump password_changed_at to invalidate every existing
    // token for this user — the logout-all-devices guarantee from
    // the JWT-revocation redesign (P0.5). A token with iat earlier
    // than this timestamp will fail the next `verify_token` check
    // even though it's still cryptographically valid up to its exp.
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "UPDATE users SET password_hash = ?, password_changed_at = ? WHERE username = ?",
    )
    .bind(&hash)
    .bind(&now)
    .bind(username)
    .execute(pool)
    .await
    .unwrap_or_else(|e| {
        eprintln!("error: update failed: {e}");
        std::process::exit(1);
    });

    println!("password updated for user: {username} (all existing tokens invalidated)");
}

/// Read a password. With `stdin=true`, reads one trimmed line from stdin —
/// no TTY required. Otherwise prompts twice on the TTY (with confirmation).
/// Both paths enforce the 8-character minimum.
fn read_password(stdin: bool) -> String {
    if stdin {
        use std::io::BufRead;
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line).unwrap_or_else(|e| {
            eprintln!("error: stdin read failed: {e}");
            std::process::exit(1);
        });
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r').to_string();
        if trimmed.len() < 8 {
            eprintln!("error: password must be at least 8 characters");
            std::process::exit(1);
        }
        trimmed
    } else {
        let password = rpassword::prompt_password("Password: ").unwrap_or_else(|e| {
            eprintln!("error: password read failed: {e}");
            std::process::exit(1);
        });
        if password.len() < 8 {
            eprintln!("error: password must be at least 8 characters");
            std::process::exit(1);
        }
        let confirm = rpassword::prompt_password("Confirm:  ").unwrap_or_else(|e| {
            eprintln!("error: password read failed: {e}");
            std::process::exit(1);
        });
        if password != confirm {
            eprintln!("error: passwords do not match");
            std::process::exit(1);
        }
        password
    }
}
