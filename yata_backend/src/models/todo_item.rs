use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TodoItem {
    pub id: String,
    pub title: String,
    pub priority: i64,
    pub is_done: bool,
    pub sort_order: i64,
    pub reminder_date: Option<String>,
    pub created_at: String,
    pub completed_at: Option<String>,
    pub scheduled_date: String,
    pub source_repeating_id: Option<String>,
    pub source_repeating_rule_name: Option<String>,
    pub reschedule_count: i64,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateItemRequest {
    pub id: String,
    pub title: String,
    pub priority: i64,
    pub scheduled_date: String,
    pub reminder_date: Option<String>,
    pub sort_order: i64,
    pub source_repeating_id: Option<String>,
    pub source_repeating_rule_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateItemRequest {
    pub title: String,
    pub priority: i64,
    pub is_done: bool,
    pub sort_order: i64,
    pub reminder_date: Option<String>,
    pub scheduled_date: String,
    pub reschedule_count: i64,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct ReorderRequest {
    pub date: String,
    pub priority: i64,
    pub ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct MoveRequest {
    pub to_priority: i64,
    pub at_index: i64,
}

#[derive(Debug, Deserialize)]
pub struct UndoneRequest {
    pub scheduled_date: String,
}

#[derive(Debug, Deserialize)]
pub struct RescheduleRequest {
    pub to_date: String,
    pub reset_count: bool,
}

#[derive(Debug, Deserialize)]
pub struct ItemsQuery {
    pub date: String,
    pub priority: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct DoneQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}
