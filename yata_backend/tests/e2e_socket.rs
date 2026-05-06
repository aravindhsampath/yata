// End-to-end test that drives the server through a real TCP
// listener — the `oneshot()` path used elsewhere bypasses
// `axum::serve`'s `into_make_service_with_connect_info`, which
// means the rate-limit layer's `SmartIpKeyExtractor` looks fine
// in unit tests but fails with 500 "Unable To Extract Key!"
// on a fresh deploy without an L7 proxy.
//
// This test catches the regression where someone accidentally
// reverts to plain `axum::serve(listener, app)` and Caddy hides
// the breakage in prod by sending `X-Forwarded-For`.

use std::net::SocketAddr;

use sqlx::SqlitePool;
use tokio::net::TcpListener;
use yata_backend::config::Config;
use yata_backend::password::hash_password;
use yata_backend::routes::build_router;

const TEST_USERNAME: &str = "e2e-user";
const TEST_PASSWORD: &str = "e2e-test-password";
const TEST_USER_ID: &str = "00000000-0000-0000-0000-0000000000e2";

/// Boot a fresh in-memory app on an ephemeral port; return the
/// `http://127.0.0.1:<port>` base URL.
async fn boot_server() -> String {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();

    let hash = hash_password(TEST_PASSWORD).unwrap();
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, created_at, password_changed_at) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(TEST_USER_ID)
    .bind(TEST_USERNAME)
    .bind(&hash)
    .bind(&now)
    .bind(&now)
    .execute(&pool)
    .await
    .unwrap();

    let cfg = Config {
        jwt_secret: "e2e-jwt-secret".to_string(),
        db_path: ":memory:".to_string(),
        port: 0,
    };

    let app = build_router(pool, cfg);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        // Mirrors `main.rs::run_server` exactly — the whole point
        // of this test is to exercise that wiring.
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });

    // Brief wait for the spawned server to bind. Polling /health
    // would be cleaner but adds a hyper dependency loop — 50ms is
    // plenty on localhost.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    format!("http://{addr}")
}

#[tokio::test]
async fn auth_token_returns_401_not_500_on_loopback() {
    // The bug we're guarding against: without ConnectInfo wiring,
    // SmartIpKeyExtractor fails on direct (non-proxied) requests
    // and tower_governor returns 500 "Unable To Extract Key!".
    // The correct behavior is to consult auth.rs and return 401
    // for bad credentials.
    let base = boot_server().await;
    let client = reqwest::Client::new();

    let res = client
        .post(format!("{base}/auth/token"))
        .json(&serde_json::json!({
            "username": TEST_USERNAME,
            "password": "WRONG-password"
        }))
        .send()
        .await
        .expect("request");

    assert_eq!(
        res.status(),
        reqwest::StatusCode::UNAUTHORIZED,
        "/auth/token must reach the handler and return 401, not 500. \
         A 500 here means ConnectInfo wiring is missing — see main.rs::run_server."
    );
}

#[tokio::test]
async fn health_response_carries_request_id() {
    // Sanity: the request-id propagation works on real sockets too,
    // not just oneshot.
    let base = boot_server().await;
    let res = reqwest::get(format!("{base}/health")).await.unwrap();
    assert_eq!(res.status(), reqwest::StatusCode::OK);
    let id = res
        .headers()
        .get("x-request-id")
        .expect("x-request-id missing on real-socket response");
    assert!(!id.to_str().unwrap().is_empty());
}

#[tokio::test]
async fn auth_token_succeeds_with_correct_credentials_via_real_socket() {
    let base = boot_server().await;
    let client = reqwest::Client::new();

    let res = client
        .post(format!("{base}/auth/token"))
        .json(&serde_json::json!({
            "username": TEST_USERNAME,
            "password": TEST_PASSWORD
        }))
        .send()
        .await
        .expect("request");

    assert_eq!(res.status(), reqwest::StatusCode::OK);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["token"].as_str().unwrap().starts_with("eyJ"));
    assert!(!body["expires_at"].as_str().unwrap().is_empty());
}
