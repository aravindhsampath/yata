// Coverage for the `/health`, `/health/db`, and `/version` endpoints
// added in P2.14. The first two are operator-facing readiness
// probes; the third reports the build identity. None of them require
// auth — they're hit by orchestrators and humans without a token.

use axum::body::Body;
use axum::http::Request;
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;
use yata_backend::test_helpers;

async fn body_json(resp: axum::response::Response) -> Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn health_returns_ok() {
    let (router, _pool) = test_helpers::app().await;
    let req = Request::builder()
        .method("GET")
        .uri("/health")
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), 200);
    let json = body_json(resp).await;
    assert_eq!(json["status"], "ok");
    // version comes from CARGO_PKG_VERSION; just assert presence.
    assert!(json["version"].as_str().is_some());
}

#[tokio::test]
async fn db_health_returns_ok_when_pool_healthy() {
    let (router, _pool) = test_helpers::app().await;
    let req = Request::builder()
        .method("GET")
        .uri("/health/db")
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), 200);
    let json = body_json(resp).await;
    assert_eq!(json["status"], "ok");
}

#[tokio::test]
async fn db_health_returns_503_when_pool_closed() {
    // Build the router with a pool we'll close before the request,
    // forcing the SELECT 1 to fail. We can't reuse `test_helpers::app()`
    // because it gives us a router with the pool already injected;
    // we close that pool and fire the request — sqlx returns
    // PoolClosed which the handler maps to 503.
    let (router, pool) = test_helpers::app().await;
    pool.close().await;
    let req = Request::builder()
        .method("GET")
        .uri("/health/db")
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), 503);
    let json = body_json(resp).await;
    assert_eq!(json["status"], "degraded");
    assert_eq!(json["detail"], "db unreachable");
}

#[tokio::test]
async fn version_returns_build_identity() {
    let (router, _pool) = test_helpers::app().await;
    let req = Request::builder()
        .method("GET")
        .uri("/version")
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), 200);
    let json = body_json(resp).await;
    // build.rs always sets these — exact value is build-dependent,
    // so just check shape + non-emptiness.
    let sha = json["git_sha"].as_str().unwrap();
    assert!(!sha.is_empty(), "git_sha should be non-empty");
    let built = json["built_at_epoch"].as_str().unwrap();
    assert!(!built.is_empty(), "built_at_epoch should be non-empty");
    let version = json["version"].as_str().unwrap();
    assert!(!version.is_empty(), "version should be non-empty");
}

#[tokio::test]
async fn version_does_not_require_auth() {
    // /version is intentionally anonymous so monitors and humans can
    // read it without a token. Just confirm we don't 401.
    let (router, _pool) = test_helpers::app().await;
    let req = Request::builder()
        .method("GET")
        .uri("/version")
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    assert_ne!(resp.status(), 401);
    assert_ne!(resp.status(), 403);
}
