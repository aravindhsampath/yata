use std::sync::Arc;

use axum::http::HeaderName;
use axum::routing::{delete, get, post, put};
use axum::{Extension, Router};
use sqlx::SqlitePool;
use tower_governor::GovernorLayer;
use tower_governor::governor::GovernorConfigBuilder;
use tower_governor::key_extractor::SmartIpKeyExtractor;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, RequestId, SetRequestIdLayer};
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::Level;

use crate::config::Config;
use crate::handlers;
use crate::rate_limit::RateLimitConfig;

/// Header name used both for the inbound request id (clients can set
/// it; we mint one if absent) and the outbound response copy. Using a
/// const rather than re-creating `HeaderName` per request avoids
/// runtime allocations for what is effectively a static string.
const X_REQUEST_ID: &str = "x-request-id";

pub fn build_router(pool: SqlitePool, config: Config) -> Router {
    build_router_with(pool, config, RateLimitConfig::default())
}

/// Test/staging entry point: build the router with a custom
/// rate-limit configuration. Used by `tests/rate_limit.rs` to swap
/// in a hostile config (`for_test_lockout`) so we can prove the
/// layer engages without real-time sleeps.
pub fn build_router_with(pool: SqlitePool, config: Config, rate_limit: RateLimitConfig) -> Router {
    // Token-bucket config for /auth/token. Wrapped in an Arc — the
    // layer requires shared ownership so multiple concurrent
    // requests can read the same bucket state.
    let auth_governor = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(rate_limit.auth_per_secs)
            .burst_size(rate_limit.auth_burst)
            .key_extractor(SmartIpKeyExtractor)
            .finish()
            .expect("rate-limit config must be valid"),
    );

    // Health: cheap, anonymous, never rate-limited (so monitoring
    // probes don't trip the bucket).
    let health = Router::new().route("/health", get(handlers::health::health));

    // Auth: rate-limited per IP. Living in its own subrouter so the
    // GovernorLayer applies only to /auth/token, not to /health or
    // any of the protected routes (those are gated by JWT bearer).
    let auth = Router::new()
        .route("/auth/token", post(handlers::auth::auth_token))
        .layer(GovernorLayer {
            config: auth_governor,
        });

    let public = Router::new().merge(health).merge(auth);

    // Protected routes (auth required)
    let protected = Router::new()
        // Token refresh — caller must already have a valid token.
        .route("/auth/refresh", post(handlers::auth::auth_refresh))
        // Todo items CRUD
        .route("/items", get(handlers::items::list_items))
        .route("/items", post(handlers::items::create_item))
        .route("/items/done", get(handlers::items::list_done_items))
        .route("/items/reorder", post(handlers::items::reorder_items))
        .route("/items/{id}", put(handlers::items::update_item))
        .route("/items/{id}", delete(handlers::items::delete_item))
        .route("/items/{id}/move", post(handlers::items::move_item))
        .route("/items/{id}/done", post(handlers::items::mark_done))
        .route("/items/{id}/undone", post(handlers::items::mark_undone))
        .route(
            "/items/{id}/reschedule",
            post(handlers::items::reschedule_item),
        )
        // Repeating items CRUD
        .route("/repeating", get(handlers::repeating::list_repeating))
        .route("/repeating", post(handlers::repeating::create_repeating))
        .route(
            "/repeating/{id}",
            put(handlers::repeating::update_repeating),
        )
        .route(
            "/repeating/{id}",
            delete(handlers::repeating::delete_repeating),
        )
        // Server operations
        .route("/operations/rollover", post(handlers::operations::rollover))
        .route(
            "/operations/materialize",
            post(handlers::operations::materialize),
        )
        // Analytics
        .route("/stats/counts", get(handlers::stats::counts))
        .route("/stats/done-count", get(handlers::stats::done_count))
        // Sync
        .route("/sync", get(handlers::sync::sync));

    // The JWT signing key is injected as an Extension<String> for the
    // AuthUser extractor. Config is also injected for handlers that need it.
    let jwt_secret = config.jwt_secret.clone();

    // Layer order is significant. `axum` applies `.layer(L)` calls
    // outermost-last (the LAST `.layer()` wraps everything). For
    // request-id propagation to work end-to-end:
    //
    //   - `SetRequestIdLayer` must be OUTERMOST so it mints/promotes
    //     the id into the request before any other layer reads it.
    //   - `TraceLayer` is in the middle, so its `make_span_with`
    //     callback sees a request that already has the id.
    //   - `PropagateRequestIdLayer` must be INNERMOST so on the
    //     return trip it runs first, copying the id from the
    //     request to the response header before downstream layers
    //     could discard it.
    //
    // Reading top-to-bottom in source: innermost first, outermost
    // last. This is the exact reverse of how a `ServiceBuilder` reads.
    let header_name = HeaderName::from_static(X_REQUEST_ID);
    Router::new()
        .merge(public)
        .merge(protected)
        .layer(Extension(pool))
        .layer(Extension(config))
        .layer(Extension(jwt_secret))
        .layer(PropagateRequestIdLayer::new(header_name.clone()))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(|req: &axum::http::Request<_>| {
                    // Pull the id out of request extensions, falling
                    // back to "-" if SetRequestIdLayer hasn't run
                    // (defensive — shouldn't happen now that it's
                    // outermost).
                    let id = req
                        .extensions()
                        .get::<RequestId>()
                        .and_then(|id| id.header_value().to_str().ok())
                        .unwrap_or("-")
                        .to_string();
                    tracing::info_span!(
                        "http",
                        method = %req.method(),
                        uri = %req.uri(),
                        request_id = %id,
                    )
                })
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
        .layer(SetRequestIdLayer::new(header_name, MakeRequestUuid))
}
