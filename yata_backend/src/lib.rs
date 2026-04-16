pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod handlers;
pub mod models;
pub mod password;
pub mod routes;

pub mod test_helpers {
    use axum::Router;
    use axum::body::Body;
    use axum::http::Request;
    use serde_json::Value;
    use sqlx::SqlitePool;

    use crate::config::Config;
    use crate::routes::build_router;

    pub async fn app() -> (Router, SqlitePool) {
        let pool = SqlitePool::connect("sqlite::memory:")
            .await
            .expect("failed to create in-memory db");

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .expect("failed to run migrations");

        let config = Config {
            secret: "test-secret".to_string(),
            db_path: ":memory:".to_string(),
            port: 0,
        };

        let router = build_router(pool.clone(), config);
        (router, pool)
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
            .header("content-type", "application/json");

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
