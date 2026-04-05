use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct RepeatingItem {
    pub id: String,
    pub title: String,
    pub frequency: i64,
    pub scheduled_time: String,
    pub scheduled_day_of_week: Option<i64>,
    pub scheduled_day_of_month: Option<i64>,
    pub scheduled_month: Option<i64>,
    pub sort_order: i64,
    pub default_urgency: i64,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateRepeatingRequest {
    pub id: String,
    pub title: String,
    pub frequency: i64,
    pub scheduled_time: String,
    pub scheduled_day_of_week: Option<i64>,
    pub scheduled_day_of_month: Option<i64>,
    pub scheduled_month: Option<i64>,
    pub sort_order: i64,
    pub default_urgency: i64,
}

#[derive(Debug, Deserialize)]
pub struct UpdateRepeatingRequest {
    pub title: String,
    pub frequency: i64,
    pub scheduled_time: String,
    pub scheduled_day_of_week: Option<i64>,
    pub scheduled_day_of_month: Option<i64>,
    pub scheduled_month: Option<i64>,
    pub sort_order: i64,
    pub default_urgency: i64,
    pub updated_at: String,
}
