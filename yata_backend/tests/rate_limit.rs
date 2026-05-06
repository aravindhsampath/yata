// Verifies /auth/token rate limiting:
//
// 1. After the per-IP burst is exhausted, the next request returns
//    429. This is the contract that protects against credential
//    stuffing.
// 2. Other public routes (/health) and authenticated routes are
//    NOT rate-limited — the layer is scoped to /auth/token only.
// 3. Two distinct IPs get distinct buckets — exhausting one does
//    not lock out the other.
//
// Tests build a custom router via `build_router_with` and an
// extreme `RateLimitConfig::for_test_lockout` (burst=2, refill
// once per hour) so we can prove engagement without any real-time
// sleeps.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use sqlx::SqlitePool;
use tower::ServiceExt;
use yata_backend::config::Config;
use yata_backend::password::hash_password;
use yata_backend::rate_limit::RateLimitConfig;
use yata_backend::routes::build_router_with;

const TEST_USERNAME: &str = "rl-test-user";
const TEST_PASSWORD: &str = "rl-test-password";
const TEST_USER_ID: &str = "00000000-0000-0000-0000-000000000099";
const TEST_JWT_SECRET: &str = "rl-test-jwt-secret";

async fn build_test_app(config: RateLimitConfig) -> axum::Router {
    let pool = SqlitePool::connect("sqlite::memory:")
        .await
        .expect("memory db");
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();

    let hash = hash_password(TEST_PASSWORD).unwrap();
    sqlx::query("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
        .bind(TEST_USER_ID)
        .bind(TEST_USERNAME)
        .bind(&hash)
        .bind("2026-04-23T00:00:00Z")
        .execute(&pool)
        .await
        .unwrap();

    let cfg = Config {
        jwt_secret: TEST_JWT_SECRET.to_string(),
        db_path: ":memory:".to_string(),
        port: 0,
    };

    build_router_with(pool, cfg, config)
}

/// `SmartIpKeyExtractor` looks at the `X-Forwarded-For` header
/// before the connection peer. `axum::oneshot` doesn't populate
/// `ConnectInfo`, so tests MUST set this header or the layer
/// returns an error response.
fn auth_request(forwarded_for: &str) -> Request<Body> {
    let body = json!({
        "username": TEST_USERNAME,
        "password": "wrong-password-on-purpose"
    });
    Request::builder()
        .method("POST")
        .uri("/auth/token")
        .header("content-type", "application/json")
        .header("x-forwarded-for", forwarded_for)
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap()
}

#[tokio::test]
async fn auth_token_returns_429_after_burst_exhausted() {
    let app = build_test_app(RateLimitConfig::for_test_lockout()).await;

    // burst = 2 → first 2 requests pass through (and hit 401 because
    // we deliberately send a wrong password — what matters is they
    // got past the limiter), 3rd request is 429.
    let mut statuses = Vec::with_capacity(3);
    for _ in 0..3 {
        let res = app
            .clone()
            .oneshot(auth_request("203.0.113.1"))
            .await
            .unwrap();
        statuses.push(res.status());
        // Drain so the connection can be reused next iteration.
        let _ = res.into_body().collect().await;
    }

    assert_eq!(
        statuses[0],
        StatusCode::UNAUTHORIZED,
        "first attempt should pass through to handler (got rate-limited?)"
    );
    assert_eq!(statuses[1], StatusCode::UNAUTHORIZED);
    assert_eq!(
        statuses[2],
        StatusCode::TOO_MANY_REQUESTS,
        "third attempt should be rate-limited"
    );
}

#[tokio::test]
async fn auth_token_429_includes_retry_after_header() {
    let app = build_test_app(RateLimitConfig::for_test_lockout()).await;

    // Burn through the burst.
    for _ in 0..2 {
        let res = app
            .clone()
            .oneshot(auth_request("203.0.113.2"))
            .await
            .unwrap();
        let _ = res.into_body().collect().await;
    }

    let res = app
        .clone()
        .oneshot(auth_request("203.0.113.2"))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        res.headers().contains_key("x-ratelimit-after")
            || res.headers().contains_key("retry-after"),
        "429 response must hint when to retry. Headers: {:?}",
        res.headers()
            .iter()
            .map(|(k, _)| k.as_str())
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn distinct_ips_have_distinct_buckets() {
    let app = build_test_app(RateLimitConfig::for_test_lockout()).await;

    // Exhaust IP A's bucket entirely.
    for _ in 0..3 {
        let res = app
            .clone()
            .oneshot(auth_request("198.51.100.1"))
            .await
            .unwrap();
        let _ = res.into_body().collect().await;
    }

    // IP B should still be able to authenticate. Hit it twice;
    // both must reach the handler (401 because wrong password).
    for i in 0..2 {
        let res = app
            .clone()
            .oneshot(auth_request("198.51.100.2"))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::UNAUTHORIZED,
            "IP B request #{i} got {} — bucket bled across IPs?",
            res.status()
        );
        let _ = res.into_body().collect().await;
    }
}

#[tokio::test]
async fn health_endpoint_is_not_rate_limited() {
    let app = build_test_app(RateLimitConfig::for_test_lockout()).await;

    // Far more requests than the auth burst would allow.
    for i in 0..20 {
        let req = Request::builder()
            .method("GET")
            .uri("/health")
            .header("x-forwarded-for", "203.0.113.99")
            .body(Body::empty())
            .unwrap();
        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::OK,
            "request #{i} to /health was rate-limited ({})",
            res.status()
        );
        let _ = res.into_body().collect().await;
    }
}
