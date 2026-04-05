use sqlx::SqlitePool;
use sqlx::sqlite::SqlitePoolOptions;

pub async fn create_pool(db_path: &str) -> SqlitePool {
    let url = format!("sqlite:{db_path}?mode=rwc");
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect(&url)
        .await
        .expect("Failed to connect to database");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("Failed to run migrations");

    pool
}
