use axum::Json;
use axum::extract::Extension;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::auth::{AuthUser, create_token};
use crate::config::Config;
use crate::error::AppError;
use crate::password::{dummy_verify, verify_password};

#[derive(Deserialize)]
pub struct AuthRequest {
    username: String,
    password: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    token: String,
    expires_at: String,
}

pub async fn auth_token(
    Extension(pool): Extension<SqlitePool>,
    Extension(config): Extension<Config>,
    Json(body): Json<AuthRequest>,
) -> Result<Json<AuthResponse>, AppError> {
    // Look up the user. On miss, still run a dummy argon2 verify so the
    // response time is indistinguishable from a wrong-password response,
    // defeating username-enumeration timing attacks.
    let row: Option<(String, String)> =
        sqlx::query_as("SELECT id, password_hash FROM users WHERE username = ?")
            .bind(&body.username)
            .fetch_optional(&pool)
            .await?;

    let Some((user_id, password_hash)) = row else {
        dummy_verify(&body.password);
        return Err(AppError::Unauthorized);
    };

    if !verify_password(&body.password, &password_hash)? {
        return Err(AppError::Unauthorized);
    }

    let (token, expires_at) = create_token(&user_id, &body.username, &config.jwt_secret)?;
    Ok(Json(AuthResponse { token, expires_at }))
}

/// Mint a fresh token for the user identified by the bearer token.
/// The caller must already hold a valid (non-stale, non-expired)
/// token; the AuthUser extractor enforces that. The newly minted
/// token has its own iat/exp so a client can stay logged in across
/// the 7-day default lifetime by refreshing periodically.
///
/// Note: a stolen token can be refreshed indefinitely until its
/// user changes their password (which bumps `password_changed_at`,
/// invalidating the original AND any tokens minted from it that
/// share the original's password change cutoff). That's the
/// trade-off of stateless JWTs without a deny-list; mitigations
/// are documented in YATA/docs/hardening_plan.md (P0.5).
pub async fn auth_refresh(
    auth: AuthUser,
    Extension(config): Extension<Config>,
) -> Result<Json<AuthResponse>, AppError> {
    let (token, expires_at) = create_token(&auth.user_id, &auth.username, &config.jwt_secret)?;
    Ok(Json(AuthResponse { token, expires_at }))
}
