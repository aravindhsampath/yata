// Verifies the observability wiring on the router itself:
//
// 1. Every response carries an `x-request-id` header. Operators
//    quote this header in bug reports — if it goes missing, we'd
//    lose the only stable correlation between client-side logs and
//    server-side spans.
// 2. Different requests get different request ids — so we can
//    actually use the id to disambiguate.
// 3. A client-supplied `x-request-id` header is preserved through
//    to the response. This lets a load balancer or upstream service
//    set the id and have it flow end-to-end.
//
// The Format::from_value unit tests live next to the implementation
// in src/observability.rs.

use axum::http::StatusCode;
use http_body_util::BodyExt;
use tower::ServiceExt;
use yata_backend::test_helpers;

#[tokio::test]
async fn every_response_has_a_request_id_header() {
    let (app, _pool) = test_helpers::app().await;

    let res = app
        .clone()
        .oneshot(test_helpers::request("GET", "/health", None, None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let id = res
        .headers()
        .get("x-request-id")
        .expect("x-request-id header missing on response");
    let id_str = id.to_str().unwrap();
    assert!(!id_str.is_empty(), "x-request-id header must not be empty");
    // Drain the body so the connection isn't dropped mid-read.
    let _ = res.into_body().collect().await;
}

#[tokio::test]
async fn distinct_requests_get_distinct_request_ids() {
    let (app, _pool) = test_helpers::app().await;

    let mut ids = std::collections::HashSet::new();
    for _ in 0..5 {
        let res = app
            .clone()
            .oneshot(test_helpers::request("GET", "/health", None, None))
            .await
            .unwrap();
        let id = res
            .headers()
            .get("x-request-id")
            .expect("missing x-request-id")
            .to_str()
            .unwrap()
            .to_string();
        let _ = res.into_body().collect().await;
        ids.insert(id);
    }

    assert_eq!(
        ids.len(),
        5,
        "expected 5 distinct request ids, got {}: {:?}",
        ids.len(),
        ids
    );
}

#[tokio::test]
async fn client_supplied_request_id_is_preserved() {
    let (app, _pool) = test_helpers::app().await;

    let supplied = "00000000-0000-0000-0000-deadbeefcafe";
    let mut req = test_helpers::request("GET", "/health", None, None);
    req.headers_mut()
        .insert("x-request-id", supplied.parse().unwrap());

    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let echoed = res
        .headers()
        .get("x-request-id")
        .expect("response is missing x-request-id")
        .to_str()
        .unwrap()
        .to_string();
    let _ = res.into_body().collect().await;

    assert_eq!(
        echoed, supplied,
        "client-supplied x-request-id should propagate through unchanged"
    );
}
