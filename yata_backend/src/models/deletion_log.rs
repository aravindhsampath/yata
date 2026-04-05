use sqlx::FromRow;

#[allow(dead_code)]
#[derive(Debug, Clone, FromRow)]
pub struct DeletionLog {
    pub id: i64,
    pub entity_type: String,
    pub entity_id: String,
    pub deleted_at: String,
}
