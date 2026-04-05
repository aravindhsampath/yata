use axum::Json;
use axum::extract::Extension;
use serde::{Deserialize, Serialize};

use crate::auth::create_token;
use crate::config::Config;
use crate::error::AppError;

#[derive(Deserialize)]
pub struct AuthRequest {
    secret: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    token: String,
    expires_at: String,
}

pub async fn auth_token(
    Extension(config): Extension<Config>,
    Json(body): Json<AuthRequest>,
) -> Result<Json<AuthResponse>, AppError> {
    if body.secret != config.secret {
        return Err(AppError::Unauthorized);
    }
    let (token, expires_at) = create_token(&config.secret)?;
    Ok(Json(AuthResponse { token, expires_at }))
}
