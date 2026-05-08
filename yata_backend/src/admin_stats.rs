//! Per-user activity stats for the admin CLI (`yata_backend stats`).
//!
//! Pulled out of `main.rs` so unit tests can drive the pure
//! aggregation function without invoking the binary. The CLI wrapper
//! in `main.rs` is a thin adapter that prints the result as an
//! aligned table.

use serde::Serialize;
use sqlx::SqlitePool;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UserStats {
    pub username: String,
    pub items_open: i64,
    pub items_done: i64,
    pub repeating: i64,
    /// ISO-8601 string of the most recent `updated_at` across the
    /// user's `todo_items` and `repeating_items`. `None` for users
    /// with no rows in either table.
    pub last_activity: Option<String>,
}

/// Aggregate per-user counts. One DB round trip per metric (4 total)
/// rather than a single LEFT JOIN — readable + each subquery is
/// already covered by the per-user composite indexes from
/// migration 001. Result is sorted by `last_activity DESC NULLS
/// LAST` so the most recently active users float to the top.
pub async fn compute_stats(pool: &SqlitePool) -> Result<Vec<UserStats>, sqlx::Error> {
    let users: Vec<(String, String)> =
        sqlx::query_as("SELECT id, username FROM users ORDER BY username ASC")
            .fetch_all(pool)
            .await?;

    let mut out = Vec::with_capacity(users.len());
    for (id, username) in users {
        let items_open: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_items WHERE user_id = ? AND is_done = 0")
                .bind(&id)
                .fetch_one(pool)
                .await?;

        let items_done: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_items WHERE user_id = ? AND is_done = 1")
                .bind(&id)
                .fetch_one(pool)
                .await?;

        let repeating: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM repeating_items WHERE user_id = ?")
                .bind(&id)
                .fetch_one(pool)
                .await?;

        // Most recent updated_at across both tables, MAX over the
        // ISO-8601 strings (sortable lexicographically — that's why
        // we store them as strings rather than INTEGER epoch).
        let last_activity: (Option<String>,) = sqlx::query_as(
            "SELECT MAX(ts) FROM (
                SELECT MAX(updated_at) AS ts FROM todo_items WHERE user_id = ?1
                UNION ALL
                SELECT MAX(updated_at) AS ts FROM repeating_items WHERE user_id = ?1
            )",
        )
        .bind(&id)
        .fetch_one(pool)
        .await?;

        out.push(UserStats {
            username,
            items_open: items_open.0,
            items_done: items_done.0,
            repeating: repeating.0,
            last_activity: last_activity.0,
        });
    }

    // Sort: last_activity DESC, NULLS LAST. Users with no activity
    // sink to the bottom so an operator scanning the top of the list
    // sees the most engaged tenants first.
    out.sort_by(|a, b| match (&a.last_activity, &b.last_activity) {
        (Some(x), Some(y)) => y.cmp(x),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => a.username.cmp(&b.username),
    });

    Ok(out)
}

/// Format a `Vec<UserStats>` as an aligned table. Pure function on
/// purpose — `main.rs` calls this and prints to stdout, tests assert
/// against the returned string.
pub fn format_stats_table(stats: &[UserStats]) -> String {
    if stats.is_empty() {
        return "no users\n".to_string();
    }

    // Column widths. Username can be arbitrary length; pad to the
    // max we see, with a sane minimum so the header still aligns
    // even with one short username.
    let username_w = stats
        .iter()
        .map(|s| s.username.len())
        .max()
        .unwrap_or(0)
        .max("USERNAME".len());

    let mut out = String::new();
    out.push_str(&format!(
        "{:<uw$}  {:>10}  {:>10}  {:>9}  {}\n",
        "USERNAME",
        "ITEMS_OPEN",
        "ITEMS_DONE",
        "REPEATING",
        "LAST_ACTIVITY",
        uw = username_w,
    ));
    for s in stats {
        out.push_str(&format!(
            "{:<uw$}  {:>10}  {:>10}  {:>9}  {}\n",
            s.username,
            s.items_open,
            s.items_done,
            s.repeating,
            s.last_activity.as_deref().unwrap_or("-"),
            uw = username_w,
        ));
    }
    out
}
