use axum::http::StatusCode;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sqlx::SqlitePool;
use tower::ServiceExt;

use yata_backend::test_helpers::{app, auth_request, request};

// ─── Health ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn health_returns_ok() {
    let (app, _pool) = app().await;
    let res = app
        .oneshot(request("GET", "/health", None, None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["status"], "ok");
    assert_eq!(body["version"], "1.0.0");
}

// ─── Auth ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn auth_with_correct_credentials() {
    let (app, _pool) = app().await;
    let res = app
        .oneshot(request(
            "POST",
            "/auth/token",
            Some(json!({"username": "test-user", "password": "test-password"})),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert!(body["token"].is_string());
    assert!(body["expires_at"].is_string());
}

#[tokio::test]
async fn auth_with_wrong_password() {
    let (app, _pool) = app().await;
    let res = app
        .oneshot(request(
            "POST",
            "/auth/token",
            Some(json!({"username": "test-user", "password": "wrong"})),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn auth_with_unknown_username() {
    let (app, _pool) = app().await;
    let res = app
        .oneshot(request(
            "POST",
            "/auth/token",
            Some(json!({"username": "nobody", "password": "whatever"})),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn protected_endpoint_without_token() {
    let (app, _pool) = app().await;
    let res = app
        .oneshot(request("GET", "/items?date=2026-04-05", None, None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

// ─── Todo Items CRUD ───────────────────────────────────────────────────────

#[tokio::test]
async fn create_and_list_items() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create an item
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "11111111-1111-1111-1111-111111111111",
                "title": "Test todo",
                "priority": 2,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let item = body_json(res).await;
    assert_eq!(item["title"], "Test todo");
    assert_eq!(item["priority"], 2);
    assert!(!item["is_done"].as_bool().unwrap());

    // List items for that date
    let res = app
        .oneshot(auth_request("GET", "/items?date=2026-04-05", None, &token))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn create_item_validates_title() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    let res = app
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "22222222-2222-2222-2222-222222222222",
                "title": "  ",
                "priority": 0,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn update_item_with_conflict_detection() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "33333333-3333-3333-3333-333333333333",
                "title": "Conflict test",
                "priority": 1,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Update with stale timestamp → should succeed (first update)
    let res = app
        .clone()
        .oneshot(auth_request(
            "PUT",
            "/items/33333333-3333-3333-3333-333333333333",
            Some(json!({
                "title": "Updated title",
                "priority": 1,
                "is_done": false,
                "sort_order": 0,
                "reminder_date": null,
                "scheduled_date": "2026-04-05",
                "reschedule_count": 0,
                "updated_at": "2099-01-01T00:00:00+00:00"
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let updated = body_json(res).await;
    assert_eq!(updated["title"], "Updated title");

    // Update with old timestamp → should conflict
    let res = app
        .oneshot(auth_request(
            "PUT",
            "/items/33333333-3333-3333-3333-333333333333",
            Some(json!({
                "title": "Stale update",
                "priority": 1,
                "is_done": false,
                "sort_order": 0,
                "reminder_date": null,
                "scheduled_date": "2026-04-05",
                "reschedule_count": 0,
                "updated_at": "2020-01-01T00:00:00+00:00"
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    let body = body_json(res).await;
    assert!(body["error"]["server_version"].is_object());
}

#[tokio::test]
async fn delete_item_is_idempotent() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Delete nonexistent → still 204
    let res = app
        .clone()
        .oneshot(auth_request(
            "DELETE",
            "/items/99999999-9999-9999-9999-999999999999",
            None,
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn mark_done_and_undone() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create item
    app.clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "44444444-4444-4444-4444-444444444444",
                "title": "Done test",
                "priority": 0,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();

    // Mark done
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items/44444444-4444-4444-4444-444444444444/done",
            None,
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let item = body_json(res).await;
    assert!(item["is_done"].as_bool().unwrap());
    assert!(item["completed_at"].is_string());

    // Mark undone
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items/44444444-4444-4444-4444-444444444444/undone",
            Some(json!({"scheduled_date": "2026-04-06"})),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let item = body_json(res).await;
    assert!(!item["is_done"].as_bool().unwrap());
    assert!(item["completed_at"].is_null());
    assert_eq!(item["scheduled_date"], "2026-04-06");
}

#[tokio::test]
async fn reschedule_item() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    app.clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "55555555-5555-5555-5555-555555555555",
                "title": "Reschedule test",
                "priority": 1,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items/55555555-5555-5555-5555-555555555555/reschedule",
            Some(json!({"to_date": "2026-04-10", "reset_count": false})),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let item = body_json(res).await;
    assert_eq!(item["scheduled_date"], "2026-04-10");
    assert_eq!(item["reschedule_count"], 1);

    // Reschedule with reset
    let res = app
        .oneshot(auth_request(
            "POST",
            "/items/55555555-5555-5555-5555-555555555555/reschedule",
            Some(json!({"to_date": "2026-04-15", "reset_count": true})),
            &token,
        ))
        .await
        .unwrap();
    let item = body_json(res).await;
    assert_eq!(item["reschedule_count"], 0);
}

// ─── Repeating Items ───────────────────────────────────────────────────────

#[tokio::test]
async fn repeating_crud() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/repeating",
            Some(json!({
                "id": "aaaa-bbbb-cccc-dddd",
                "title": "Daily standup",
                "frequency": 0,
                "scheduled_time": "09:00:00",
                "scheduled_day_of_week": null,
                "scheduled_day_of_month": null,
                "scheduled_month": null,
                "sort_order": 0,
                "default_urgency": 2
            })),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // List
    let res = app
        .clone()
        .oneshot(auth_request("GET", "/repeating", None, &token))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 1);

    // Delete (should cascade to linked undone items)
    let res = app
        .oneshot(auth_request(
            "DELETE",
            "/repeating/aaaa-bbbb-cccc-dddd",
            None,
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

// ─── Operations ────────────────────────────────────────────────────────────

#[tokio::test]
async fn rollover_moves_overdue_items() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create an overdue item
    app.clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "66666666-6666-6666-6666-666666666666",
                "title": "Overdue task",
                "priority": 2,
                "scheduled_date": "2026-04-01",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/operations/rollover",
            Some(json!({"to_date": "2026-04-05"})),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["rolled_over_count"], 1);

    // Verify the item moved
    let res = app
        .oneshot(auth_request("GET", "/items?date=2026-04-05", None, &token))
        .await
        .unwrap();
    let body = body_json(res).await;
    let items = body["items"].as_array().unwrap();
    assert!(items.iter().any(|i| i["title"] == "Overdue task"));
}

#[tokio::test]
async fn materialize_creates_occurrences() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create a daily repeating rule
    app.clone()
        .oneshot(auth_request(
            "POST",
            "/repeating",
            Some(json!({
                "id": "77777777-7777-7777-7777-777777777777",
                "title": "Daily standup",
                "frequency": 0,
                "scheduled_time": "09:00:00",
                "scheduled_day_of_week": null,
                "scheduled_day_of_month": null,
                "scheduled_month": null,
                "sort_order": 0,
                "default_urgency": 2
            })),
            &token,
        ))
        .await
        .unwrap();

    // Materialize for 3 days
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/operations/materialize",
            Some(json!({"start_date": "2026-04-05", "end_date": "2026-04-07"})),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["created_count"], 3);

    // Materialize again → should dedup
    let res = app
        .oneshot(auth_request(
            "POST",
            "/operations/materialize",
            Some(json!({"start_date": "2026-04-05", "end_date": "2026-04-07"})),
            &token,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(body["created_count"], 0);
}

// ─── Stats ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn stats_counts_and_done_count() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    // Create items
    for (id_suffix, priority) in [(1, 0), (2, 1), (3, 2)] {
        app.clone()
            .oneshot(auth_request(
                "POST",
                "/items",
                Some(json!({
                    "id": format!("aabbccdd-0000-0000-0000-{id_suffix:012}"),
                    "title": format!("Task {id_suffix}"),
                    "priority": priority,
                    "scheduled_date": "2026-04-05",
                    "reminder_date": null,
                    "sort_order": 0,
                    "source_repeating_id": null,
                    "source_repeating_rule_name": null
                })),
                &token,
            ))
            .await
            .unwrap();
    }

    // Counts
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/stats/counts?dates=2026-04-05",
            None,
            &token,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    let day = &body["counts"]["2026-04-05"];
    assert_eq!(day["0"], 1);
    assert_eq!(day["1"], 1);
    assert_eq!(day["2"], 1);

    // Done count (none done yet)
    let res = app
        .oneshot(auth_request(
            "GET",
            "/stats/done-count?date=2026-04-05",
            None,
            &token,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(body["count"], 0);
}

// ─── Sync ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn sync_returns_changes_since_timestamp() {
    let (app, pool) = app().await;
    let token = get_token(&pool).await;

    let before = chrono::Utc::now().to_rfc3339();

    // Create an item
    app.clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": "88888888-8888-8888-8888-888888888888",
                "title": "Sync test",
                "priority": 0,
                "scheduled_date": "2026-04-05",
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            &token,
        ))
        .await
        .unwrap();

    // Sync since before creation
    let url = format!("/sync?since={before}");
    let res = app
        .clone()
        .oneshot(auth_request("GET", &url, None, &token))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["items"]["upserted"].as_array().unwrap().len(), 1);
    assert!(body["server_time"].is_string());

    // Delete the item and check deletion log appears in sync
    let after_create = body["server_time"].as_str().unwrap().to_string();
    app.clone()
        .oneshot(auth_request(
            "DELETE",
            "/items/88888888-8888-8888-8888-888888888888",
            None,
            &token,
        ))
        .await
        .unwrap();

    let url = format!("/sync?since={after_create}");
    let res = app
        .oneshot(auth_request("GET", &url, None, &token))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert!(
        body["items"]["deleted"]
            .as_array()
            .unwrap()
            .contains(&json!("88888888-8888-8888-8888-888888888888"))
    );
}

// ─── Helpers ───────────────────────────────────────────────────────────────

async fn body_json(res: axum::response::Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

async fn get_token(pool: &SqlitePool) -> String {
    let _ = pool; // pool passed for consistency — token is self-contained JWT
    yata_backend::test_helpers::test_user_token()
}
