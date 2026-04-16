use axum::routing::{delete, get, post, put};
use axum::{Extension, Router};
use sqlx::SqlitePool;

use crate::config::Config;
use crate::handlers;

pub fn build_router(pool: SqlitePool, config: Config) -> Router {
    // Public routes (no auth required)
    let public = Router::new()
        .route("/health", get(handlers::health::health))
        .route("/auth/token", post(handlers::auth::auth_token));

    // Protected routes (auth required)
    let protected = Router::new()
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
    Router::new()
        .merge(public)
        .merge(protected)
        .layer(Extension(pool))
        .layer(Extension(config))
        .layer(Extension(jwt_secret))
}
