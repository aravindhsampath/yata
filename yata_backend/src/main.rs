use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;
use yata_backend::config::Config;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let config = Config::from_env();
    let pool = yata_backend::db::create_pool(&config.db_path).await;

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

    let app = yata_backend::routes::build_router(pool, config.clone());
    let addr = format!("0.0.0.0:{}", config.port);
    tracing::info!("YATA server listening on {addr}");

    let listener = TcpListener::bind(&addr).await.expect("failed to bind");
    axum::serve(listener, app).await.expect("server error");
}
