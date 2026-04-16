use axum::Json;
use axum::extract::{Extension, Path, Query};
use axum::http::StatusCode;
use chrono::Utc;
use serde::Serialize;
use sqlx::SqlitePool;

use crate::auth::AuthUser;
use crate::error::AppError;
use crate::models::{
    CreateItemRequest, DoneQuery, ItemsQuery, MoveRequest, ReorderRequest, RescheduleRequest,
    TodoItem, UndoneRequest, UpdateItemRequest,
};

#[derive(Serialize)]
pub struct ItemsResponse {
    items: Vec<TodoItem>,
}

#[derive(Serialize)]
pub struct DoneItemsResponse {
    items: Vec<TodoItem>,
    total: i64,
}

// GET /items?date=YYYY-MM-DD&priority=N
pub async fn list_items(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<ItemsQuery>,
) -> Result<Json<ItemsResponse>, AppError> {
    let items = if let Some(priority) = query.priority {
        sqlx::query_as::<_, TodoItem>(
            "SELECT * FROM todo_items WHERE user_id = ? AND scheduled_date = ? AND priority = ? ORDER BY sort_order ASC",
        )
        .bind(&auth.user_id)
        .bind(&query.date)
        .bind(priority)
        .fetch_all(&pool)
        .await?
    } else {
        sqlx::query_as::<_, TodoItem>(
            "SELECT * FROM todo_items WHERE user_id = ? AND scheduled_date = ? ORDER BY sort_order ASC",
        )
        .bind(&auth.user_id)
        .bind(&query.date)
        .fetch_all(&pool)
        .await?
    };
    Ok(Json(ItemsResponse { items }))
}

// GET /items/done?limit=25&offset=0
pub async fn list_done_items(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<DoneQuery>,
) -> Result<Json<DoneItemsResponse>, AppError> {
    let limit = query.limit.unwrap_or(25);
    let offset = query.offset.unwrap_or(0);

    let total: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM todo_items WHERE user_id = ? AND is_done = 1")
            .bind(&auth.user_id)
            .fetch_one(&pool)
            .await?;

    let items = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND is_done = 1 ORDER BY completed_at DESC LIMIT ? OFFSET ?",
    )
    .bind(&auth.user_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&pool)
    .await?;

    Ok(Json(DoneItemsResponse {
        items,
        total: total.0,
    }))
}

// POST /items
pub async fn create_item(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Json(body): Json<CreateItemRequest>,
) -> Result<(StatusCode, Json<TodoItem>), AppError> {
    if body.title.trim().is_empty() {
        return Err(AppError::ValidationError(
            "title must not be empty".to_string(),
        ));
    }

    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO todo_items (id, user_id, title, priority, is_done, sort_order, reminder_date, created_at, completed_at, scheduled_date, source_repeating_id, source_repeating_rule_name, reschedule_count, updated_at)
         VALUES (?, ?, ?, ?, 0, ?, ?, ?, NULL, ?, ?, ?, 0, ?)",
    )
    .bind(&body.id)
    .bind(&auth.user_id)
    .bind(&body.title)
    .bind(body.priority)
    .bind(body.sort_order)
    .bind(&body.reminder_date)
    .bind(&now)
    .bind(&body.scheduled_date)
    .bind(&body.source_repeating_id)
    .bind(&body.source_repeating_rule_name)
    .bind(&now)
    .execute(&pool)
    .await?;

    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&body.id)
    .fetch_one(&pool)
    .await?;

    Ok((StatusCode::CREATED, Json(item)))
}

// PUT /items/:id
pub async fn update_item(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
    Json(body): Json<UpdateItemRequest>,
) -> Result<Json<TodoItem>, AppError> {
    if body.title.trim().is_empty() {
        return Err(AppError::ValidationError(
            "title must not be empty".to_string(),
        ));
    }

    let existing = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound)?;

    // Conflict detection: if server's updated_at is newer than client's, reject
    if existing.updated_at > body.updated_at {
        let server_version =
            serde_json::to_value(&existing).map_err(|e| AppError::Internal(e.to_string()))?;
        return Err(AppError::Conflict(server_version));
    }

    let now = Utc::now().to_rfc3339();

    // Track completed_at transitions
    let completed_at = if body.is_done && !existing.is_done {
        Some(now.clone())
    } else if body.is_done {
        existing.completed_at
    } else {
        None
    };

    sqlx::query(
        "UPDATE todo_items SET title = ?, priority = ?, is_done = ?, sort_order = ?, reminder_date = ?, scheduled_date = ?, reschedule_count = ?, completed_at = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(&body.title)
    .bind(body.priority)
    .bind(body.is_done)
    .bind(body.sort_order)
    .bind(&body.reminder_date)
    .bind(&body.scheduled_date)
    .bind(body.reschedule_count)
    .bind(&completed_at)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(item))
}

// DELETE /items/:id
pub async fn delete_item(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let result = sqlx::query("DELETE FROM todo_items WHERE user_id = ? AND id = ?")
        .bind(&auth.user_id)
        .bind(&id)
        .execute(&pool)
        .await?;

    if result.rows_affected() == 0 {
        // Idempotent — 204 even if already deleted or belongs to another user.
        return Ok(StatusCode::NO_CONTENT);
    }

    // Record in deletion log for sync
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO deletion_log (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'todoItem', ?, ?)",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .bind(&now)
    .execute(&pool)
    .await?;

    Ok(StatusCode::NO_CONTENT)
}

// POST /items/reorder
pub async fn reorder_items(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Json(body): Json<ReorderRequest>,
) -> Result<Json<ItemsResponse>, AppError> {
    for (index, id) in body.ids.iter().enumerate() {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "UPDATE todo_items SET sort_order = ?, updated_at = ? WHERE user_id = ? AND id = ? AND scheduled_date = ? AND priority = ?",
        )
        .bind(index as i64)
        .bind(&now)
        .bind(&auth.user_id)
        .bind(id)
        .bind(&body.date)
        .bind(body.priority)
        .execute(&pool)
        .await?;
    }

    let items = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND scheduled_date = ? AND priority = ? ORDER BY sort_order ASC",
    )
    .bind(&auth.user_id)
    .bind(&body.date)
    .bind(body.priority)
    .fetch_all(&pool)
    .await?;

    Ok(Json(ItemsResponse { items }))
}

// POST /items/:id/move
pub async fn move_item(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
    Json(body): Json<MoveRequest>,
) -> Result<Json<TodoItem>, AppError> {
    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound)?;

    let now = Utc::now().to_rfc3339();

    // Shift existing items in the target priority down to make room
    sqlx::query(
        "UPDATE todo_items SET sort_order = sort_order + 1, updated_at = ? WHERE user_id = ? AND scheduled_date = ? AND priority = ? AND sort_order >= ? AND id != ?",
    )
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&item.scheduled_date)
    .bind(body.to_priority)
    .bind(body.at_index)
    .bind(&id)
    .execute(&pool)
    .await?;

    // Move the item
    sqlx::query(
        "UPDATE todo_items SET priority = ?, sort_order = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(body.to_priority)
    .bind(body.at_index)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    let updated = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(updated))
}

// POST /items/:id/done
pub async fn mark_done(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
) -> Result<Json<TodoItem>, AppError> {
    let now = Utc::now().to_rfc3339();

    let result = sqlx::query(
        "UPDATE todo_items SET is_done = 1, completed_at = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(&now)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }

    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(item))
}

// POST /items/:id/undone
pub async fn mark_undone(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
    Json(body): Json<UndoneRequest>,
) -> Result<Json<TodoItem>, AppError> {
    let now = Utc::now().to_rfc3339();

    let result = sqlx::query(
        "UPDATE todo_items SET is_done = 0, completed_at = NULL, scheduled_date = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(&body.scheduled_date)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }

    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(item))
}

// POST /items/:id/reschedule
pub async fn reschedule_item(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Path(id): Path<String>,
    Json(body): Json<RescheduleRequest>,
) -> Result<Json<TodoItem>, AppError> {
    let existing = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound)?;

    let now = Utc::now().to_rfc3339();
    let new_count = if body.reset_count {
        0
    } else {
        existing.reschedule_count + 1
    };

    sqlx::query(
        "UPDATE todo_items SET scheduled_date = ?, reschedule_count = ?, updated_at = ? WHERE user_id = ? AND id = ?",
    )
    .bind(&body.to_date)
    .bind(new_count)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&id)
    .execute(&pool)
    .await?;

    let item = sqlx::query_as::<_, TodoItem>(
        "SELECT * FROM todo_items WHERE user_id = ? AND id = ?",
    )
    .bind(&auth.user_id)
    .bind(&id)
    .fetch_one(&pool)
    .await?;

    Ok(Json(item))
}
