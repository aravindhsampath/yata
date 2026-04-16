use clap::{Parser, Subcommand};
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;
use yata_backend::config::Config;
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
    },
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let cli = Cli::parse();
    let config = Config::from_env();
    let pool = yata_backend::db::create_pool(&config.db_path).await;

    match cli.command {
        None => run_server(pool, config).await,
        Some(Command::CreateUser { username }) => cmd_create_user(&pool, &username).await,
        Some(Command::ListUsers) => cmd_list_users(&pool).await,
        Some(Command::DeleteUser { username }) => cmd_delete_user(&pool, &username).await,
        Some(Command::ResetPassword { username }) => cmd_reset_password(&pool, &username).await,
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
    axum::serve(listener, app).await.expect("server error");
}

async fn cmd_create_user(pool: &SqlitePool, username: &str) {
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

    let password = prompt_password_twice();
    let hash = hash_password(&password).unwrap_or_else(|e| {
        eprintln!("error: password hash failed: {e:?}");
        std::process::exit(1);
    });

    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
        .bind(&id)
        .bind(username)
        .bind(&hash)
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

async fn cmd_reset_password(pool: &SqlitePool, username: &str) {
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

    let password = prompt_password_twice();
    let hash = hash_password(&password).unwrap_or_else(|e| {
        eprintln!("error: password hash failed: {e:?}");
        std::process::exit(1);
    });

    sqlx::query("UPDATE users SET password_hash = ? WHERE username = ?")
        .bind(&hash)
        .bind(username)
        .execute(pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("error: update failed: {e}");
            std::process::exit(1);
        });

    println!("password updated for user: {username}");
}

fn prompt_password_twice() -> String {
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
