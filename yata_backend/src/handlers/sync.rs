use axum::Json;
use axum::extract::{Extension, Query};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::auth::AuthUser;
use crate::error::AppError;
use crate::models::{RepeatingItem, TodoItem};

#[derive(Deserialize)]
pub struct SyncQuery {
    since: String,
}

#[derive(Serialize)]
pub struct SyncResponse {
    items: SyncGroup<TodoItem>,
    repeating: SyncGroup<RepeatingItem>,
    server_time: String,
}

#[derive(Serialize)]
pub struct SyncGroup<T> {
    upserted: Vec<T>,
    deleted: Vec<String>,
}

// GET /sync?since=ISO8601
pub async fn sync(
    _auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<SyncQuery>,
) -> Result<Json<SyncResponse>, AppError> {
    let upserted_items =
        sqlx::query_as::<_, TodoItem>("SELECT * FROM todo_items WHERE updated_at > ?")
            .bind(&query.since)
            .fetch_all(&pool)
            .await?;

    let upserted_repeating =
        sqlx::query_as::<_, RepeatingItem>("SELECT * FROM repeating_items WHERE updated_at > ?")
            .bind(&query.since)
            .fetch_all(&pool)
            .await?;

    let deleted_items: Vec<(String,)> = sqlx::query_as(
        "SELECT entity_id FROM deletion_log WHERE entity_type = 'todoItem' AND deleted_at > ?",
    )
    .bind(&query.since)
    .fetch_all(&pool)
    .await?;

    let deleted_repeating: Vec<(String,)> = sqlx::query_as(
        "SELECT entity_id FROM deletion_log WHERE entity_type = 'repeatingItem' AND deleted_at > ?",
    )
    .bind(&query.since)
    .fetch_all(&pool)
    .await?;

    Ok(Json(SyncResponse {
        items: SyncGroup {
            upserted: upserted_items,
            deleted: deleted_items.into_iter().map(|(id,)| id).collect(),
        },
        repeating: SyncGroup {
            upserted: upserted_repeating,
            deleted: deleted_repeating.into_iter().map(|(id,)| id).collect(),
        },
        server_time: Utc::now().to_rfc3339(),
    }))
}
