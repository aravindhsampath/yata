pub mod auth;
pub mod backup;
pub mod config;
pub mod db;
pub mod error;
pub mod handlers;
pub mod models;
pub mod observability;
pub mod password;
pub mod rate_limit;
pub mod routes;
// `pub mod time;` removed in P1.11. Its sole inhabitant
// (`is_server_newer`) was the optimistic-concurrency comparator
// for `updated_at`; the conflict-detection redesign dropped that
// entire approach. See YATA/docs/conflict_resolution_redesign.md.

pub mod test_helpers {
    use axum::Router;
    use axum::body::Body;
    use axum::http::Request;
    use serde_json::Value;
    use sqlx::SqlitePool;

    use crate::config::Config;
    use crate::password::hash_password;
    use crate::routes::build_router;

    pub const TEST_USER_ID: &str = "00000000-0000-0000-0000-000000000001";
    pub const TEST_USERNAME: &str = "test-user";
    pub const TEST_PASSWORD: &str = "test-password";
    pub const TEST_JWT_SECRET: &str = "test-jwt-secret";

    /// Spin up an in-memory app with the default test user pre-seeded.
    pub async fn app() -> (Router, SqlitePool) {
        let pool = SqlitePool::connect("sqlite::memory:")
            .await
            .expect("failed to create in-memory db");

        // Enable foreign keys on this connection (in-memory pools don't go
        // through our db::create_pool path).
        sqlx::query("PRAGMA foreign_keys = ON")
            .execute(&pool)
            .await
            .expect("failed to enable foreign_keys");

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .expect("failed to run migrations");

        seed_user(&pool, TEST_USER_ID, TEST_USERNAME, TEST_PASSWORD).await;

        let config = Config {
            jwt_secret: TEST_JWT_SECRET.to_string(),
            db_path: ":memory:".to_string(),
            port: 0,
        };

        let router = build_router(pool.clone(), config);
        (router, pool)
    }

    /// Insert a user row. Used by tests that need a second tenant for
    /// isolation checks.
    pub async fn seed_user(pool: &SqlitePool, id: &str, username: &str, password: &str) {
        let hash = hash_password(password).expect("hash_password failed in test");
        let now = chrono::Utc::now().to_rfc3339();
        sqlx::query("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
            .bind(id)
            .bind(username)
            .bind(&hash)
            .bind(&now)
            .execute(pool)
            .await
            .expect("failed to seed user");
    }

    /// Mint a JWT for the default test user.
    pub fn test_user_token() -> String {
        let (token, _) = crate::auth::create_token(TEST_USER_ID, TEST_USERNAME, TEST_JWT_SECRET)
            .expect("create_token failed in test");
        token
    }

    /// Mint a JWT for an arbitrary user (use with `seed_user` for multi-tenant tests).
    pub fn token_for(user_id: &str, username: &str) -> String {
        let (token, _) = crate::auth::create_token(user_id, username, TEST_JWT_SECRET)
            .expect("create_token failed in test");
        token
    }

    pub fn request(
        method: &str,
        uri: &str,
        body: Option<Value>,
        token: Option<&str>,
    ) -> Request<Body> {
        let body_bytes = body
            .map(|b| serde_json::to_vec(&b).unwrap())
            .unwrap_or_default();
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            // SmartIpKeyExtractor on /auth/token needs *some* IP to
            // build a rate-limit bucket key — without ConnectInfo
            // (which axum::oneshot doesn't populate) we'd get a 500.
            // 127.0.0.1 is the safe loopback default; tests that
            // care about per-IP behavior (`tests/rate_limit.rs`)
            // build their own requests with explicit forwarded
            // addresses.
            .header("x-forwarded-for", "127.0.0.1");

        if let Some(t) = token {
            builder = builder.header("authorization", format!("Bearer {t}"));
        }

        builder.body(Body::from(body_bytes)).unwrap()
    }

    pub fn auth_request(
        method: &str,
        uri: &str,
        body: Option<Value>,
        token: &str,
    ) -> Request<Body> {
        request(method, uri, body, Some(token))
    }
}
