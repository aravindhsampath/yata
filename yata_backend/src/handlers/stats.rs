use std::collections::HashMap;

use axum::Json;
use axum::extract::{Extension, Query};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::auth::AuthUser;
use crate::error::AppError;

#[derive(Deserialize)]
pub struct CountsQuery {
    dates: String,
}

#[derive(Serialize)]
pub struct CountsResponse {
    counts: HashMap<String, HashMap<String, i64>>,
}

#[derive(Deserialize)]
pub struct DoneCountQuery {
    date: String,
}

#[derive(Serialize)]
pub struct DoneCountResponse {
    count: i64,
}

// GET /stats/counts?dates=2026-04-05,2026-04-06
pub async fn counts(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<CountsQuery>,
) -> Result<Json<CountsResponse>, AppError> {
    let dates: Vec<&str> = query.dates.split(',').collect();
    let mut result: HashMap<String, HashMap<String, i64>> = HashMap::new();

    for date in dates {
        let date = date.trim();
        let rows: Vec<(i64, i64)> = sqlx::query_as(
            "SELECT priority, COUNT(*) FROM todo_items WHERE user_id = ? AND scheduled_date = ? AND is_done = 0 GROUP BY priority",
        )
        .bind(&auth.user_id)
        .bind(date)
        .fetch_all(&pool)
        .await?;

        let mut priority_counts = HashMap::new();
        // Initialize all priorities to 0
        priority_counts.insert("0".to_string(), 0);
        priority_counts.insert("1".to_string(), 0);
        priority_counts.insert("2".to_string(), 0);

        for (priority, count) in rows {
            priority_counts.insert(priority.to_string(), count);
        }

        result.insert(date.to_string(), priority_counts);
    }

    Ok(Json(CountsResponse { counts: result }))
}

// GET /stats/done-count?date=2026-04-05
pub async fn done_count(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<DoneCountQuery>,
) -> Result<Json<DoneCountResponse>, AppError> {
    let (count,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM todo_items WHERE user_id = ? AND scheduled_date = ? AND is_done = 1",
    )
    .bind(&auth.user_id)
    .bind(&query.date)
    .fetch_one(&pool)
    .await?;

    Ok(Json(DoneCountResponse { count }))
}
