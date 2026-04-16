use std::str::FromStr;

use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

pub async fn create_pool(db_path: &str) -> SqlitePool {
    let url = format!("sqlite:{db_path}?mode=rwc");
    let options = SqliteConnectOptions::from_str(&url)
        .expect("invalid sqlite connect options")
        .foreign_keys(true);

    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await
        .expect("Failed to connect to database");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("Failed to run migrations");

    pool
}
