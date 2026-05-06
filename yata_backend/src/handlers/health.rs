use std::time::Duration;

use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::{Extension, Json};
use serde::Serialize;
use sqlx::SqlitePool;

#[derive(Serialize)]
pub struct HealthResponse {
    status: &'static str,
    version: &'static str,
}

/// Cheap liveness probe — answers 200 as long as the process is
/// running and the router is dispatching. Does not touch the DB; for
/// that, monitors should hit `/health/db`.
pub async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

#[derive(Serialize)]
pub struct DbHealthResponse {
    status: &'static str,
    detail: Option<&'static str>,
}

/// Database-backed readiness probe. Issues `SELECT 1` against the
/// pool with a 1s timeout. Returns:
///
/// - 200 `{"status":"ok"}` when the round trip succeeds.
/// - 503 `{"status":"degraded","detail":"db unreachable"}` on any
///   pool error or timeout.
///
/// The 1s budget is intentional: the pool's default acquire timeout
/// is 30s. A slow probe under load is itself a problem we want to
/// surface, not absorb. Use this endpoint for orchestrator readiness
/// checks rather than `/health` (which lies happily while the DB is
/// dead — a connection-pool exhaustion or stuck migration still
/// answers 200).
pub async fn db_health(Extension(pool): Extension<SqlitePool>) -> impl IntoResponse {
    let probe = sqlx::query_scalar::<_, i64>("SELECT 1").fetch_one(&pool);
    let result = tokio::time::timeout(Duration::from_secs(1), probe).await;

    match result {
        Ok(Ok(_)) => (
            StatusCode::OK,
            Json(DbHealthResponse {
                status: "ok",
                detail: None,
            }),
        ),
        // Timeout or pool error → 503. We don't echo the underlying
        // sqlx error to the client (it can leak schema/host info);
        // the structured tracing log carries the detail.
        Ok(Err(e)) => {
            tracing::warn!(error = %e, "db_health: SELECT 1 failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(DbHealthResponse {
                    status: "degraded",
                    detail: Some("db unreachable"),
                }),
            )
        }
        Err(_) => {
            tracing::warn!("db_health: SELECT 1 timed out");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(DbHealthResponse {
                    status: "degraded",
                    detail: Some("db unreachable"),
                }),
            )
        }
    }
}

#[derive(Serialize)]
pub struct VersionResponse {
    /// Short git SHA at build time. `"unknown"` if `git` was not
    /// available when `build.rs` ran (e.g. building from a source
    /// tarball without a `.git` directory).
    git_sha: &'static str,
    /// Unix epoch seconds (string) recorded by `build.rs`. Operators
    /// convert this to a date locally; the server stays string-typed
    /// to avoid lying about precision.
    built_at_epoch: &'static str,
    /// `Cargo.toml` package version.
    version: &'static str,
}

/// Build identity. Used by operators to confirm `which build is
/// running` without needing ssh access. Anonymous on purpose: this is
/// the same kind of fingerprint a reverse proxy already exposes via
/// the `Server` header.
pub async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        git_sha: env!("GIT_SHA"),
        built_at_epoch: env!("BUILT_AT_EPOCH"),
        version: env!("CARGO_PKG_VERSION"),
    })
}
