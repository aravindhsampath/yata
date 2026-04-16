//! Cross-tenant isolation tests.
//!
//! These tests verify that a user's queries never read, mutate, or reveal
//! the existence of another user's data. Every handler is covered.

use axum::http::StatusCode;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

use yata_backend::test_helpers::{
    TEST_USER_ID, TEST_USERNAME, app, auth_request, seed_user, test_user_token, token_for,
};

const OTHER_USER_ID: &str = "00000000-0000-0000-0000-0000000000b0";
const OTHER_USERNAME: &str = "other-user";
const OTHER_PASSWORD: &str = "other-password";

/// Spin up the app with a second tenant already seeded. Returns tokens
/// for both users.
async fn two_tenant_app() -> (axum::Router, String, String) {
    let (app, pool) = app().await;
    seed_user(&pool, OTHER_USER_ID, OTHER_USERNAME, OTHER_PASSWORD).await;

    let token_a = test_user_token();
    let token_b = token_for(OTHER_USER_ID, OTHER_USERNAME);
    (app, token_a, token_b)
}

async fn body_json(res: axum::response::Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Helper: user A creates an item and returns its id.
async fn create_item_as(
    app: &axum::Router,
    token: &str,
    id: &str,
    date: &str,
) -> StatusCode {
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/items",
            Some(json!({
                "id": id,
                "title": "isolated",
                "priority": 2,
                "scheduled_date": date,
                "reminder_date": null,
                "sort_order": 0,
                "source_repeating_id": null,
                "source_repeating_rule_name": null
            })),
            token,
        ))
        .await
        .unwrap();
    res.status()
}

// ─── Items isolation ───────────────────────────────────────────────────────

#[tokio::test]
async fn user_b_cannot_see_user_a_items_in_list() {
    let (app, token_a, token_b) = two_tenant_app().await;

    assert_eq!(
        create_item_as(&app, &token_a, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "2026-04-10")
            .await,
        StatusCode::CREATED
    );

    // User B asks for items on the same date → empty.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-10",
            None,
            &token_b,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn user_b_gets_404_updating_user_a_item() {
    let (app, token_a, token_b) = two_tenant_app().await;

    let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1";
    assert_eq!(
        create_item_as(&app, &token_a, id, "2026-04-10").await,
        StatusCode::CREATED
    );

    // Grab the item's updated_at so we pass conflict detection.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-10",
            None,
            &token_a,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    let updated_at = body["items"][0]["updated_at"].as_str().unwrap().to_string();

    // User B tries to PUT user A's item.
    let res = app
        .clone()
        .oneshot(auth_request(
            "PUT",
            &format!("/items/{id}"),
            Some(json!({
                "title": "hijacked",
                "priority": 0,
                "is_done": false,
                "sort_order": 0,
                "reminder_date": null,
                "scheduled_date": "2026-04-10",
                "reschedule_count": 0,
                "updated_at": updated_at
            })),
            &token_b,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn user_b_delete_of_user_a_item_is_silent_noop() {
    let (app, token_a, token_b) = two_tenant_app().await;

    let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2";
    assert_eq!(
        create_item_as(&app, &token_a, id, "2026-04-10").await,
        StatusCode::CREATED
    );

    // User B DELETE — idempotent 204, but user A's row must remain.
    let res = app
        .clone()
        .oneshot(auth_request("DELETE", &format!("/items/{id}"), None, &token_b))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // User A still sees their item.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-10",
            None,
            &token_a,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn user_b_mark_done_on_user_a_item_returns_404() {
    let (app, token_a, token_b) = two_tenant_app().await;

    let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3";
    assert_eq!(
        create_item_as(&app, &token_a, id, "2026-04-10").await,
        StatusCode::CREATED
    );

    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            &format!("/items/{id}/done"),
            None,
            &token_b,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

// ─── Sync isolation ────────────────────────────────────────────────────────

#[tokio::test]
async fn sync_never_returns_other_users_items_or_deletions() {
    let (app, token_a, token_b) = two_tenant_app().await;

    // User A creates & deletes an item.
    let id_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa4";
    assert_eq!(
        create_item_as(&app, &token_a, id_a, "2026-04-10").await,
        StatusCode::CREATED
    );
    let res = app
        .clone()
        .oneshot(auth_request(
            "DELETE",
            &format!("/items/{id_a}"),
            None,
            &token_a,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // User B syncs since the epoch — should see nothing of A.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/sync?since=1970-01-01T00:00:00Z",
            None,
            &token_b,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;

    assert_eq!(
        body["items"]["upserted"].as_array().unwrap().len(),
        0,
        "user B saw user A's upserts"
    );
    assert_eq!(
        body["items"]["deleted"].as_array().unwrap().len(),
        0,
        "user B saw user A's deletions"
    );
}

// ─── Stats isolation ───────────────────────────────────────────────────────

#[tokio::test]
async fn stats_counts_scope_to_user() {
    let (app, token_a, token_b) = two_tenant_app().await;

    // A has 2 items, B has 1, on the same date.
    for (i, token) in [(0, &token_a), (1, &token_a), (2, &token_b)] {
        let id = format!("bbbbbbbb-bbbb-bbbb-bbbb-{i:012}");
        assert_eq!(
            create_item_as(&app, token, &id, "2026-04-11").await,
            StatusCode::CREATED
        );
    }

    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/stats/counts?dates=2026-04-11",
            None,
            &token_a,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    let counts = &body["counts"]["2026-04-11"];
    let total: i64 = counts
        .as_object()
        .unwrap()
        .values()
        .map(|v| v.as_i64().unwrap_or(0))
        .sum();
    assert_eq!(total, 2, "user A's count must exclude user B's row");

    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/stats/counts?dates=2026-04-11",
            None,
            &token_b,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    let counts = &body["counts"]["2026-04-11"];
    let total: i64 = counts
        .as_object()
        .unwrap()
        .values()
        .map(|v| v.as_i64().unwrap_or(0))
        .sum();
    assert_eq!(total, 1, "user B's count must exclude user A's rows");
}

// ─── Repeating isolation ───────────────────────────────────────────────────

#[tokio::test]
async fn user_b_cannot_see_user_a_repeating_rules() {
    let (app, token_a, token_b) = two_tenant_app().await;

    let rule_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/repeating",
            Some(json!({
                "id": rule_id,
                "title": "A's rule",
                "frequency": 0,
                "scheduled_time": "09:00:00",
                "scheduled_day_of_week": null,
                "scheduled_day_of_month": null,
                "scheduled_month": null,
                "sort_order": 0,
                "default_urgency": 2
            })),
            &token_a,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // User B lists → empty.
    let res = app
        .clone()
        .oneshot(auth_request("GET", "/repeating", None, &token_b))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 0);
}

// ─── Rollover isolation ────────────────────────────────────────────────────

#[tokio::test]
async fn rollover_only_touches_callers_rows() {
    let (app, token_a, token_b) = two_tenant_app().await;

    // Both users have an overdue item on 2026-04-01.
    for (i, token) in [(0, &token_a), (1, &token_b)] {
        let id = format!("dddddddd-dddd-dddd-dddd-{i:012}");
        assert_eq!(
            create_item_as(&app, token, &id, "2026-04-01").await,
            StatusCode::CREATED
        );
    }

    // User A rolls over to 2026-04-10.
    let res = app
        .clone()
        .oneshot(auth_request(
            "POST",
            "/operations/rollover",
            Some(json!({"to_date": "2026-04-10"})),
            &token_a,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["rolled_over_count"], 1, "A should roll over only their one item");

    // User B's item is still on the old date.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-01",
            None,
            &token_b,
        ))
        .await
        .unwrap();
    let body = body_json(res).await;
    assert_eq!(
        body["items"].as_array().unwrap().len(),
        1,
        "user B's overdue item was disturbed by user A's rollover"
    );
}

// ─── Auth smoke (sanity): tokens are distinct and per-user claim works ─────

#[tokio::test]
async fn tokens_are_distinct_per_user() {
    let (_app, token_a, token_b) = two_tenant_app().await;
    assert_ne!(token_a, token_b);
    // Both tokens should still decode with the test jwt secret, and carry
    // the right user_id.
    let claims_a = yata_backend::auth::verify_token(
        &token_a,
        yata_backend::test_helpers::TEST_JWT_SECRET,
    )
    .unwrap();
    let claims_b = yata_backend::auth::verify_token(
        &token_b,
        yata_backend::test_helpers::TEST_JWT_SECRET,
    )
    .unwrap();
    assert_eq!(claims_a.user_id, TEST_USER_ID);
    assert_eq!(claims_a.username, TEST_USERNAME);
    assert_eq!(claims_b.user_id, OTHER_USER_ID);
    assert_eq!(claims_b.username, OTHER_USERNAME);
}
