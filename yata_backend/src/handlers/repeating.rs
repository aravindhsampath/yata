use axum::Json;
use axum::extract::{Extension, Path};
use axum::http::StatusCode;
use chrono::Utc;
use serde::Serialize;
use sqlx::SqlitePool;

use crate::auth::AuthUser;
use crate::error::AppError;
use crate::models::{CreateRepeatingRequest, RepeatingItem, UpdateRepeatingRequest};

#[derive(Serialize)]
pub struct RepeatingResponse {
    items: Vec<RepeatingItem>,
}

// GET /repeating
pub async fn list_repeating(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
) -> Result<Json<RepeatingResponse>, AppError> {
    let items = sqlx::query_as::<_, RepeatingItem>(
        "SELECT * FROM repeating_items WHERE user_id = ? ORDER BY sort_order ASC",
    )
    .bind(&auth.user_id)
    .fetch_all(&pool)
    .await?;
    Ok(Json(RepeatingResponse { items }))
}

// POST /repeating
pub async fn create_repeating(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Json(body): Json<CreateRepeatingRequest>,
) -> Result<(StatusCode, Json<RepeatingItem>), AppError> {
    if body.title.trim().is_empty() {
        return Err(AppError::ValidationError(
            "title must not be empty".to_string(),
        ));
    }

    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO repeating_items (id, user_id, title, frequency, scheduled_time, scheduled_day_of_week, scheduled_day_of_month, scheduled_month, sort_order, default_urgency, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&body.id)
    .bind(&auth.user_id)
    .bind(&body.title)
    .bind(body.frequency)
    .bind(&body.scheduled_time)
    .bind(body.scheduled_day_of_week)
    .bind(body.scheduled_day_of_month)
    .bind(body.scheduled_month)
    .bind(body.sort_order)
    .bind(body.default_urgency)
    .bind(&now)
    .execute(&pool)
    .await?;

    let item = sqlx::query_as::<_, RepeatingItem>(
        "SELECT * FROM repeating_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&body.id)
    .fetch_one(&pool)
    .await?;

    Ok((StatusCode::CREATED, Json(item)))
}

// PUT /repeating/:id
pub async fn update_repeating(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
    Json(body): Json<UpdateRepeatingRequest>,
) -> Result<Json<RepeatingItem>, AppError> {
    if body.title.trim().is_empty() {
        return Err(AppError::ValidationError(
            "title must not be empty".to_string(),
        ));
    }

    let existing = sqlx::query_as::<_, RepeatingItem>(
        "SELECT * FROM repeating_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound)?;

    if crate::time::is_server_newer(&existing.updated_at, &body.updated_at) {
        let server_version =
            serde_json::to_value(&existing).map_err(|e| AppError::Internal(e.to_string()))?;
        return Err(AppError::Conflict(server_version));
    }

    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "UPDATE repeating_items SET title = ?, frequency = ?, scheduled_time = ?, scheduled_day_of_week = ?, scheduled_day_of_month = ?, scheduled_month = ?, sort_order = ?, default_urgency = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(&body.title)
    .bind(body.frequency)
    .bind(&body.scheduled_time)
    .bind(body.scheduled_day_of_week)
    .bind(body.scheduled_day_of_month)
    .bind(body.scheduled_month)
    .bind(body.sort_order)
    .bind(body.default_urgency)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    let item = sqlx::query_as::<_, RepeatingItem>(
        "SELECT * FROM repeating_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(item))
}

// DELETE /repeating/:id — cascades: deletes undone linked TodoItems
pub async fn delete_repeating(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let result = sqlx::query("DELETE FROM repeating_items WHERE user_id = ? AND id = ?")
        .bind(&auth.user_id)
        .bind(&id)
        .execute(&pool)
        .await?;

    if result.rows_affected() == 0 {
        return Ok(StatusCode::NO_CONTENT);
    }

    let now = Utc::now().to_rfc3339();

    // Cascade: delete undone TodoItems linked to this repeating rule (scoped to this user).
    let linked_ids: Vec<(String,)> = sqlx::query_as(
        "SELECT id FROM todo_items WHERE user_id = ? AND source_repeating_id = ? AND is_done = 0",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_all(&pool)
    .await?;

    sqlx::query(
        "DELETE FROM todo_items WHERE user_id = ? AND source_repeating_id = ? AND is_done = 0",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    for (item_id,) in &linked_ids {
        sqlx::query(
            "INSERT INTO deletion_log (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'todoItem', ?, ?)",
        )
        .bind(&auth.user_id)
        .bind(item_id)
        .bind(&now)
        .execute(&pool)
        .await?;
    }

    sqlx::query(
        "INSERT INTO deletion_log (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'repeatingItem', ?, ?)",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .bind(&now)
    .execute(&pool)
    .await?;

    Ok(StatusCode::NO_CONTENT)
}
