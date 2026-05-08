// Coverage for the `yata_backend stats` admin subcommand (P3.22).
// We test the pure aggregation function `compute_stats` plus the
// `format_stats_table` formatter — the CLI wrapper in `main.rs` is
// a four-line adapter and isn't worth a binary-level test.

use yata_backend::admin_stats::{UserStats, compute_stats, format_stats_table};
use yata_backend::test_helpers;

/// Insert a `todo_items` row directly via SQL (bypassing handlers)
/// so the test controls user_id and is_done explicitly.
async fn insert_item(
    pool: &sqlx::SqlitePool,
    id: &str,
    user_id: &str,
    is_done: i32,
    updated_at: &str,
) {
    sqlx::query(
        "INSERT INTO todo_items
            (id, user_id, title, is_done, scheduled_date, created_at, updated_at)
         VALUES (?, ?, 'test', ?, '2026-04-15', ?, ?)",
    )
    .bind(id)
    .bind(user_id)
    .bind(is_done)
    .bind(updated_at)
    .bind(updated_at)
    .execute(pool)
    .await
    .unwrap();
}

async fn insert_repeating(pool: &sqlx::SqlitePool, id: &str, user_id: &str, updated_at: &str) {
    sqlx::query(
        "INSERT INTO repeating_items
            (id, user_id, title, scheduled_time, updated_at)
         VALUES (?, ?, 'rule', '09:00', ?)",
    )
    .bind(id)
    .bind(user_id)
    .bind(updated_at)
    .execute(pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn stats_counts_per_user_correctly() {
    let (_router, pool) = test_helpers::app().await;
    // Seed a second user so we can verify isolation.
    test_helpers::seed_user(&pool, "user-b-id", "bob", "bob-password").await;

    // Alice (TEST_USER_ID): 2 open, 1 done, 1 repeating.
    insert_item(
        &pool,
        "a1",
        test_helpers::TEST_USER_ID,
        0,
        "2026-04-22T11:08:09Z",
    )
    .await;
    insert_item(
        &pool,
        "a2",
        test_helpers::TEST_USER_ID,
        0,
        "2026-04-21T11:00:00Z",
    )
    .await;
    insert_item(
        &pool,
        "a3",
        test_helpers::TEST_USER_ID,
        1,
        "2026-04-20T11:00:00Z",
    )
    .await;
    insert_repeating(
        &pool,
        "ar1",
        test_helpers::TEST_USER_ID,
        "2026-04-19T08:00:00Z",
    )
    .await;

    // Bob: 1 open, 0 done, 0 repeating.
    insert_item(&pool, "b1", "user-b-id", 0, "2026-04-19T08:14:53Z").await;

    let stats = compute_stats(&pool).await.unwrap();
    assert_eq!(stats.len(), 2);

    // Sorted by last_activity DESC — alice (2026-04-22) first.
    assert_eq!(stats[0].username, "test-user");
    assert_eq!(stats[0].items_open, 2);
    assert_eq!(stats[0].items_done, 1);
    assert_eq!(stats[0].repeating, 1);
    assert_eq!(
        stats[0].last_activity.as_deref(),
        Some("2026-04-22T11:08:09Z")
    );

    assert_eq!(stats[1].username, "bob");
    assert_eq!(stats[1].items_open, 1);
    assert_eq!(stats[1].items_done, 0);
    assert_eq!(stats[1].repeating, 0);
    assert_eq!(
        stats[1].last_activity.as_deref(),
        Some("2026-04-19T08:14:53Z")
    );
}

#[tokio::test]
async fn stats_user_with_no_data_has_null_last_activity() {
    let (_router, pool) = test_helpers::app().await;
    let stats = compute_stats(&pool).await.unwrap();
    assert_eq!(stats.len(), 1);
    assert_eq!(stats[0].username, "test-user");
    assert_eq!(stats[0].items_open, 0);
    assert_eq!(stats[0].items_done, 0);
    assert_eq!(stats[0].repeating, 0);
    assert!(stats[0].last_activity.is_none());
}

#[tokio::test]
async fn stats_sort_pushes_inactive_users_last() {
    let (_router, pool) = test_helpers::app().await;
    test_helpers::seed_user(&pool, "ghost-id", "ghost", "ghost-password").await;
    // test-user has activity, ghost does not.
    insert_item(
        &pool,
        "x1",
        test_helpers::TEST_USER_ID,
        0,
        "2026-04-22T00:00:00Z",
    )
    .await;

    let stats = compute_stats(&pool).await.unwrap();
    assert_eq!(stats[0].username, "test-user");
    assert_eq!(stats[1].username, "ghost");
    assert!(stats[1].last_activity.is_none());
}

#[test]
fn format_stats_empty_prints_no_users() {
    let out = format_stats_table(&[]);
    assert_eq!(out, "no users\n");
}

#[test]
fn format_stats_renders_aligned_table() {
    let stats = vec![
        UserStats {
            username: "alice".into(),
            items_open: 142,
            items_done: 418,
            repeating: 7,
            last_activity: Some("2026-04-22T11:08:09Z".into()),
        },
        UserStats {
            username: "bob".into(),
            items_open: 3,
            items_done: 14,
            repeating: 0,
            last_activity: Some("2026-04-19T08:14:53Z".into()),
        },
    ];

    let out = format_stats_table(&stats);
    // Header line includes all column names.
    assert!(out.contains("USERNAME"));
    assert!(out.contains("ITEMS_OPEN"));
    assert!(out.contains("ITEMS_DONE"));
    assert!(out.contains("REPEATING"));
    assert!(out.contains("LAST_ACTIVITY"));
    // Both users appear with their counts.
    assert!(out.contains("alice"));
    assert!(out.contains("142"));
    assert!(out.contains("bob"));
    assert!(out.contains("2026-04-19T08:14:53Z"));
}

#[test]
fn format_stats_handles_missing_last_activity_with_dash() {
    let stats = vec![UserStats {
        username: "ghost".into(),
        items_open: 0,
        items_done: 0,
        repeating: 0,
        last_activity: None,
    }];
    let out = format_stats_table(&stats);
    // Last column for the row should be "-" when last_activity is None.
    assert!(out.lines().nth(1).unwrap().trim_end().ends_with('-'));
}
