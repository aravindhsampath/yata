use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;

#[derive(Debug)]
pub enum AppError {
    Unauthorized,
    NotFound,
    Conflict(serde_json::Value),
    ValidationError(String),
    Internal(String),
}

#[derive(Serialize)]
struct ErrorBody {
    error: ErrorDetail,
}

#[derive(Serialize)]
struct ErrorDetail {
    code: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    server_version: Option<serde_json::Value>,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message, server_version) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Token invalid or expired".to_string(),
                None,
            ),
            Self::NotFound => (
                StatusCode::NOT_FOUND,
                "not_found",
                "Entity does not exist".to_string(),
                None,
            ),
            Self::Conflict(sv) => (
                StatusCode::CONFLICT,
                "conflict",
                "Item was modified on server since your last sync".to_string(),
                Some(sv),
            ),
            Self::ValidationError(msg) => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "validation_error",
                msg,
                None,
            ),
            Self::Internal(msg) => {
                tracing::error!("Internal error: {msg}");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "server_error",
                    "Unexpected failure".to_string(),
                    None,
                )
            }
        };

        let body = ErrorBody {
            error: ErrorDetail {
                code,
                message,
                server_version,
            },
        };

        (status, axum::Json(body)).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        Self::Internal(e.to_string())
    }
}

impl From<jsonwebtoken::errors::Error> for AppError {
    fn from(_: jsonwebtoken::errors::Error) -> Self {
        Self::Unauthorized
    }
}
