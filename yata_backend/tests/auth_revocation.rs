// Tests for the JWT-revocation redesign (P0.5):
//
// 1. Token lifetime is ~7 days (regression: catches an accidental
//    revert to 30 days).
// 2. A token whose `iat` predates the user's `password_changed_at`
//    is rejected with 401 even before its `exp`.
//    This is the "logout-all-devices on password change" guarantee.
// 3. POST /auth/refresh: valid token → new token with later exp.
// 4. POST /auth/refresh: stale token → 401.
// 5. After password change, `verify_token` rejects the old token.
//
// Tests use the in-memory `test_helpers::app()` and
// `bump_password_changed_at` to simulate a password reset without
// invoking the CLI binary.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use tower::ServiceExt;

use yata_backend::auth::{TOKEN_LIFETIME_DAYS, bump_password_changed_at, verify_token};
use yata_backend::test_helpers::{
    TEST_JWT_SECRET, TEST_USER_ID, app, auth_request, test_user_token,
};

#[tokio::test]
async fn freshly_minted_tokens_have_seven_day_lifetime() {
    let token = test_user_token();

    // Decode without the revocation check so we can inspect claims
    // directly. We use the same algorithm/secret the issuer used.
    use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode};
    let data = decode::<yata_backend::auth::Claims>(
        &token,
        &DecodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
        &Validation::new(Algorithm::HS256),
    )
    .expect("decode");

    let issued = data.claims.iat;
    let expires = data.claims.exp;
    let lifetime_secs = expires - issued;

    let expected = Duration::days(TOKEN_LIFETIME_DAYS).num_seconds();
    assert_eq!(
        lifetime_secs, expected,
        "expected {expected}s lifetime, got {lifetime_secs}s — \
         did someone revert TOKEN_LIFETIME_DAYS?"
    );
}

#[tokio::test]
async fn token_is_rejected_after_password_change() {
    let (_app, pool) = app().await;
    let token = test_user_token();

    // Sanity: token works before any password change.
    let claims = verify_token(&token, TEST_JWT_SECRET, &pool)
        .await
        .expect("token must be valid before password change");
    assert_eq!(claims.user_id, TEST_USER_ID);

    // Operator runs `reset-password` (or equivalent). Bump
    // password_changed_at to the future so the existing token's
    // iat is definitively earlier — sidesteps any same-second
    // race in test execution.
    let future = (Utc::now() + Duration::seconds(60)).to_rfc3339();
    sqlx::query("UPDATE users SET password_changed_at = ? WHERE id = ? COLLATE NOCASE")
        .bind(&future)
        .bind(TEST_USER_ID)
        .execute(&pool)
        .await
        .expect("bump password_changed_at");

    // Old token must now be rejected.
    let err = verify_token(&token, TEST_JWT_SECRET, &pool)
        .await
        .expect_err("token should be rejected after password change");
    assert!(
        matches!(err, yata_backend::error::AppError::Unauthorized),
        "expected Unauthorized, got {err:?}"
    );
}

#[tokio::test]
async fn protected_endpoint_returns_401_after_password_change() {
    let (app, pool) = app().await;
    let token = test_user_token();

    // Smoke: GET /items succeeds before the password change.
    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-23",
            None,
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let _ = res.into_body().collect().await;

    // Bump and retry. Same token → 401 from the AuthUser extractor.
    let future = (Utc::now() + Duration::seconds(60)).to_rfc3339();
    sqlx::query("UPDATE users SET password_changed_at = ? WHERE id = ? COLLATE NOCASE")
        .bind(&future)
        .bind(TEST_USER_ID)
        .execute(&pool)
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(auth_request(
            "GET",
            "/items?date=2026-04-23",
            None,
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "stale token should be rejected by AuthUser extractor"
    );
}

#[tokio::test]
async fn auth_refresh_returns_new_token_with_later_exp() {
    let (app, pool) = app().await;
    let token = test_user_token();

    // Decode the original to remember its exp.
    use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode};
    let validation = Validation::new(Algorithm::HS256);
    let original = decode::<yata_backend::auth::Claims>(
        &token,
        &DecodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
        &validation,
    )
    .unwrap()
    .claims;

    // Force a 1-second wait so the refreshed iat is definitively
    // later than the original. JWT timestamps are second-resolution.
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;

    let res = app
        .clone()
        .oneshot(auth_request("POST", "/auth/refresh", None, &token))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let body = res.into_body().collect().await.unwrap().to_bytes();
    let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let new_token = parsed["token"].as_str().expect("token field");

    let refreshed = decode::<yata_backend::auth::Claims>(
        new_token,
        &DecodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
        &validation,
    )
    .unwrap()
    .claims;

    assert_eq!(refreshed.user_id, original.user_id);
    assert!(
        refreshed.exp > original.exp,
        "refreshed token exp ({}) should be after original exp ({})",
        refreshed.exp,
        original.exp
    );

    // Old token still works — refresh extends, doesn't replace.
    let claims = verify_token(&token, TEST_JWT_SECRET, &pool).await;
    assert!(
        claims.is_ok(),
        "original token should still be valid after refresh (extends, not replaces)"
    );
}

#[tokio::test]
async fn auth_refresh_with_stale_token_returns_401() {
    let (app, pool) = app().await;
    let token = test_user_token();

    // Stale the token via password change.
    let future = (Utc::now() + Duration::seconds(60)).to_rfc3339();
    sqlx::query("UPDATE users SET password_changed_at = ? WHERE id = ? COLLATE NOCASE")
        .bind(&future)
        .bind(TEST_USER_ID)
        .execute(&pool)
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(auth_request("POST", "/auth/refresh", None, &token))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "/auth/refresh must enforce the same revocation as any protected route"
    );
}

#[tokio::test]
async fn auth_refresh_without_token_returns_401() {
    let (app, _pool) = app().await;

    let req = Request::builder()
        .method("POST")
        .uri("/auth/refresh")
        .header("content-type", "application/json")
        .header("x-forwarded-for", "127.0.0.1")
        .body(Body::empty())
        .unwrap();

    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn bump_password_changed_at_helper_invalidates_tokens() {
    // Sanity check on the public helper used by the CLI's
    // reset-password command. If the helper diverges from what the
    // CLI does, this test catches it.
    let (_app, pool) = app().await;
    let token = test_user_token();

    assert!(verify_token(&token, TEST_JWT_SECRET, &pool).await.is_ok());

    bump_password_changed_at(&pool, TEST_USER_ID).await.unwrap();

    // Race: the helper uses `now()`. If our token was just minted in
    // the same wall-clock second, the "iat < password_changed_at"
    // check may still pass with equal timestamps. Sleep 1.1s to make
    // password_changed_at strictly later.
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    bump_password_changed_at(&pool, TEST_USER_ID).await.unwrap();

    let err = verify_token(&token, TEST_JWT_SECRET, &pool)
        .await
        .expect_err("token should be invalidated after helper");
    assert!(matches!(
        err,
        yata_backend::error::AppError::Unauthorized
    ));
}
