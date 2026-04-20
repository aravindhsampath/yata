use axum::Json;
use axum::extract::Extension;
use chrono::{Datelike, NaiveDate, Utc, Weekday};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::auth::AuthUser;
use crate::error::AppError;
use crate::models::RepeatingItem;

#[derive(Deserialize)]
pub struct RolloverRequest {
    to_date: String,
}

#[derive(Serialize)]
pub struct RolloverResponse {
    rolled_over_count: u64,
}

#[derive(Deserialize)]
pub struct MaterializeRequest {
    start_date: String,
    end_date: String,
}

#[derive(Serialize)]
pub struct MaterializeResponse {
    created_count: i64,
}

// POST /operations/rollover
pub async fn rollover(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Json(body): Json<RolloverRequest>,
) -> Result<Json<RolloverResponse>, AppError> {
    let now = Utc::now().to_rfc3339();

    let result = sqlx::query(
        "UPDATE todo_items SET scheduled_date = ?, reschedule_count = reschedule_count + 1, updated_at = ? WHERE user_id = ? AND scheduled_date < ? AND is_done = 0",
    )
    .bind(&body.to_date)
    .bind(&now)
    .bind(&auth.user_id)
    .bind(&body.to_date)
    .execute(&pool)
    .await?;

    Ok(Json(RolloverResponse {
        rolled_over_count: result.rows_affected(),
    }))
}

// POST /operations/materialize
pub async fn materialize(
    auth: AuthUser,
    Extension(pool): Extension<SqlitePool>,
    Json(body): Json<MaterializeRequest>,
) -> Result<Json<MaterializeResponse>, AppError> {
    let start = NaiveDate::parse_from_str(&body.start_date, "%Y-%m-%d")
        .map_err(|_| AppError::ValidationError("invalid start_date format".to_string()))?;
    let end = NaiveDate::parse_from_str(&body.end_date, "%Y-%m-%d")
        .map_err(|_| AppError::ValidationError("invalid end_date format".to_string()))?;

    let rules = sqlx::query_as::<_, RepeatingItem>(
        "SELECT * FROM repeating_items WHERE user_id = ?",
    )
    .bind(&auth.user_id)
    .fetch_all(&pool)
    .await?;

    let mut created_count: i64 = 0;

    for rule in &rules {
        let firing_dates = compute_firing_dates(rule, start, end);

        for date in firing_dates {
            let date_str = date.format("%Y-%m-%d").to_string();

            // Dedup: skip if an item already exists for this rule + date
            let (count,): (i64,) = sqlx::query_as(
                "SELECT COUNT(*) FROM todo_items WHERE user_id = ? AND source_repeating_id = ? COLLATE NOCASE AND scheduled_date = ?",
            )
            .bind(&auth.user_id)
            .bind(&rule.id)
            .bind(&date_str)
            .fetch_one(&pool)
            .await?;

            if count > 0 {
                continue;
            }

            let item_id = uuid::Uuid::new_v4().to_string();
            let now = Utc::now().to_rfc3339();

            sqlx::query(
                "INSERT INTO todo_items (id, user_id, title, priority, is_done, sort_order, reminder_date, created_at, completed_at, scheduled_date, source_repeating_id, source_repeating_rule_name, reschedule_count, updated_at)
                 VALUES (?, ?, ?, ?, 0, 0, NULL, ?, NULL, ?, ?, ?, 0, ?)",
            )
            .bind(&item_id)
            .bind(&auth.user_id)
            .bind(&rule.title)
            .bind(rule.default_urgency)
            .bind(&now)
            .bind(&date_str)
            .bind(&rule.id)
            .bind(&rule.title)
            .bind(&now)
            .execute(&pool)
            .await?;

            created_count += 1;
        }
    }

    Ok(Json(MaterializeResponse { created_count }))
}

fn compute_firing_dates(rule: &RepeatingItem, start: NaiveDate, end: NaiveDate) -> Vec<NaiveDate> {
    let mut dates = Vec::new();
    let mut current = start;

    while current <= end {
        let fires = match rule.frequency {
            0 => true, // daily
            1 => {
                // every workday (Mon-Fri)
                let wd = current.weekday();
                wd != Weekday::Sat && wd != Weekday::Sun
            }
            2 => {
                // weekly — check day_of_week (1=Sun..7=Sat)
                if let Some(dow) = rule.scheduled_day_of_week {
                    let target = match dow {
                        1 => Weekday::Sun,
                        2 => Weekday::Mon,
                        3 => Weekday::Tue,
                        4 => Weekday::Wed,
                        5 => Weekday::Thu,
                        6 => Weekday::Fri,
                        7 => Weekday::Sat,
                        _ => return dates,
                    };
                    current.weekday() == target
                } else {
                    false
                }
            }
            3 => {
                // monthly — check day_of_month
                rule.scheduled_day_of_month
                    .is_some_and(|dom| current.day() == dom as u32)
            }
            4 => {
                // yearly — check month and day_of_month
                rule.scheduled_month
                    .is_some_and(|m| current.month() == m as u32)
                    && rule
                        .scheduled_day_of_month
                        .is_some_and(|dom| current.day() == dom as u32)
            }
            _ => false,
        };

        if fires {
            dates.push(current);
        }
        current += chrono::Duration::days(1);
    }

    dates
}
