use axum::Json;
use axum::extract::Extension;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::auth::create_token;
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
