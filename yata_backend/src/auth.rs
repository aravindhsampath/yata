use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use chrono::{DateTime, Duration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::error::AppError;

/// The one JWT algorithm we issue and accept. `Validation::default()`
/// accepts multiple algorithms, which opens algorithm-confusion attacks
/// (e.g. attacker-supplied `alg: none` or `alg: RS256` against an HMAC
/// secret). Pin to HS256 here and only here.
const JWT_ALG: Algorithm = Algorithm::HS256;

/// Lifetime of a freshly minted token. Down from 30 days as part of
/// the JWT-revocation hardening (P0.5). With `password_changed_at`
/// providing instant logout-all-devices, 7 days is a good default
/// trade between user friction and exposure window for a leak.
pub const TOKEN_LIFETIME_DAYS: i64 = 7;

/// JWT claims for a per-user session token.
///
/// `iat` (issued-at) is critical: when the operator runs
/// `reset-password` we bump `users.password_changed_at` to "now",
/// and any token with `iat < password_changed_at` is rejected by
/// `verify_token` even though it remains cryptographically valid
/// up to `exp`. This is the logout-all-devices guarantee that
/// makes 7-day tokens safe.
#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    /// Stable user identifier (UUID as string).
    pub user_id: String,
    /// Username at the time of token issue. Used for display only;
    /// authorization decisions rely on `user_id`.
    pub username: String,
    /// Issued-at (seconds since epoch). Required.
    pub iat: i64,
    /// Expiry (seconds since epoch). Required, validated by jsonwebtoken.
    pub exp: i64,
}

/// Mint a JWT for the given user, signed with the server's jwt_secret.
/// Returns (token, expires_at_rfc3339).
pub fn create_token(
    user_id: &str,
    username: &str,
    jwt_secret: &str,
) -> Result<(String, String), AppError> {
    let now = Utc::now();
    let expires_at = now + Duration::days(TOKEN_LIFETIME_DAYS);
    let claims = Claims {
        user_id: user_id.to_string(),
        username: username.to_string(),
        iat: now.timestamp(),
        exp: expires_at.timestamp(),
    };
    let token = encode(
        &Header::new(JWT_ALG),
        &claims,
        &EncodingKey::from_secret(jwt_secret.as_bytes()),
    )?;
    Ok((token, expires_at.to_rfc3339()))
}

/// Verify a JWT signature + expiry, then enforce the per-user
/// revocation cutoff: if the user's `password_changed_at` is later
/// than the token's `iat`, the token is rejected as stale.
///
/// This is async because the revocation lookup hits SQLite. The
/// AuthUser extractor calls this from `from_request_parts` which
/// is already async, so no churn for handlers.
pub async fn verify_token(
    token: &str,
    jwt_secret: &str,
    pool: &SqlitePool,
) -> Result<Claims, AppError> {
    // Step 1: cryptographic validation. Pinned algorithm; default
    // exp validation. Old tokens (pre-P0.5, missing `iat`) fail
    // here — Claims requires the field. That's the intentional
    // logout-all-devices effect of the deploy.
    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::new(JWT_ALG),
    )?;
    let claims = data.claims;

    // Step 2: revocation check. Look up the user's
    // password_changed_at and compare against iat. We use COLLATE
    // NOCASE on the user_id matcher to match the rest of the
    // codebase (Swift sends uppercase UUIDs, Rust stores
    // lowercase).
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT password_changed_at FROM users WHERE id = ? COLLATE NOCASE",
    )
    .bind(&claims.user_id)
    .fetch_optional(pool)
    .await?;

    let Some((pw_changed,)) = row else {
        // The user this token references no longer exists (deleted
        // by the operator). Reject — there's nothing legitimate
        // they could be doing.
        return Err(AppError::Unauthorized);
    };

    let pw_changed_ts = DateTime::parse_from_rfc3339(&pw_changed)
        .map(|dt| dt.timestamp())
        // Malformed timestamps in the DB shouldn't lock users out.
        // Treat as epoch (no revocation) and let downstream checks
        // catch the underlying corruption.
        .unwrap_or(0);

    if claims.iat < pw_changed_ts {
        return Err(AppError::Unauthorized);
    }

    Ok(claims)
}

/// Synchronous helper: bump a user's `password_changed_at` to the
/// current instant. Called by the CLI's `reset-password` (and
/// future `revoke-tokens`) commands; also used by tests.
pub async fn bump_password_changed_at(pool: &SqlitePool, user_id: &str) -> Result<(), AppError> {
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE users SET password_changed_at = ? WHERE id = ? COLLATE NOCASE")
        .bind(&now)
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
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

        // Pool is needed for the password_changed_at revocation
        // check inside verify_token.
        let pool = parts
            .extensions
            .get::<SqlitePool>()
            .ok_or(AppError::Internal(
                "missing SqlitePool in extensions".to_string(),
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
        let claims = verify_token(token, &jwt_secret, &pool).await?;
        Ok(Self {
            user_id: claims.user_id,
            username: claims.username,
        })
    }
}
