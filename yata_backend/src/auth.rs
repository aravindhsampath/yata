use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use chrono::{Duration, Utc};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

use crate::error::AppError;

/// JWT claims for a per-user session token.
#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    /// Stable user identifier (UUID as string).
    pub user_id: String,
    /// Username at the time of token issue. Used for display; authorization
    /// decisions rely on `user_id`.
    pub username: String,
    /// Expiry (seconds since epoch).
    pub exp: i64,
}

/// Mint a JWT for the given user, signed with the server's jwt_secret.
/// Returns (token, expires_at_rfc3339).
pub fn create_token(
    user_id: &str,
    username: &str,
    jwt_secret: &str,
) -> Result<(String, String), AppError> {
    let expires_at = Utc::now() + Duration::days(30);
    let claims = Claims {
        user_id: user_id.to_string(),
        username: username.to_string(),
        exp: expires_at.timestamp(),
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(jwt_secret.as_bytes()),
    )?;
    Ok((token, expires_at.to_rfc3339()))
}

pub fn verify_token(token: &str, jwt_secret: &str) -> Result<Claims, AppError> {
    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::default(),
    )?;
    Ok(data.claims)
}

/// Axum extractor that validates the Bearer token and exposes the
/// authenticated user's identity to handlers.
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub user_id: String,
    pub username: String,
}

impl<S: Send + Sync> FromRequestParts<S> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let jwt_secret = parts
            .extensions
            .get::<String>()
            .ok_or(AppError::Internal(
                "missing jwt_secret in extensions".to_string(),
            ))?
            .clone();

        let header = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or(AppError::Unauthorized)?;

        let token = header
            .strip_prefix("Bearer ")
            .ok_or(AppError::Unauthorized)?;
        let claims = verify_token(token, &jwt_secret)?;
        Ok(Self {
            user_id: claims.user_id,
            username: claims.username,
        })
    }
}
