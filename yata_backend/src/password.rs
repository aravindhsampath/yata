use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

use crate::error::AppError;

/// Hash a plaintext password with Argon2id using a fresh random salt.
pub fn hash_password(plain: &str) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let hash = argon2
        .hash_password(plain.as_bytes(), &salt)
        .map_err(|e| AppError::Internal(format!("password hash failed: {e}")))?
        .to_string();
    Ok(hash)
}

/// Verify a plaintext password against an Argon2 hash.
/// Returns `true` on match, `false` otherwise. Never returns `Err` for a bad password —
/// only for malformed hash strings.
pub fn verify_password(plain: &str, hash: &str) -> Result<bool, AppError> {
    let parsed = PasswordHash::new(hash)
        .map_err(|e| AppError::Internal(format!("invalid password hash stored: {e}")))?;
    Ok(Argon2::default()
        .verify_password(plain.as_bytes(), &parsed)
        .is_ok())
}

/// Perform a dummy Argon2 verify to equalize timing on the "unknown username"
/// branch of authentication and prevent username-enumeration timing attacks.
/// The hash is generated once on first call and cached.
pub fn dummy_verify(plain: &str) {
    use std::sync::OnceLock;
    static DUMMY_HASH: OnceLock<String> = OnceLock::new();
    let hash = DUMMY_HASH.get_or_init(|| {
        // Hash of a random value; only the time spent in argon2 matters.
        hash_password("dummy-never-matches-any-real-password").unwrap_or_default()
    });
    if let Ok(parsed) = PasswordHash::new(hash.as_str()) {
        let _ = Argon2::default().verify_password(plain.as_bytes(), &parsed);
    }
}
