//! Password hashing — Argon2id wrappers + the constant-time dummy
//! verify used to defeat username enumeration on the login path.
//!
//! ## Parameters
//!
//! We use [`Argon2::default()`], which the `argon2` crate (v0.5)
//! resolves to **Argon2id with `m = 19_456 KiB`, `t = 2`, `p = 1`**
//! (memory cost ~19 MiB, time cost 2 iterations, single lane).
//! Hash output: 32 bytes, salt: 16 bytes, encoded in the standard
//! `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>` PHC string.
//!
//! These are the OWASP "second recommended option" baseline from
//! the 2024 Password Storage Cheat Sheet — adequate for a personal-
//! scale multi-tenant deployment running on a small VPS where each
//! verify call must complete in <100 ms on a single core.
//!
//! ## When to bump
//!
//! Bench `verify_password` on the production box. If a single hash
//! completes in significantly under **50 ms** (e.g. on faster CPUs
//! that ship in the next few years), bump the parameters. Two
//! reasonable next steps:
//!
//! 1. Switch to `argon2::Params::new(64 * 1024, 3, 1, None)` for
//!    `m = 64 MiB`, `t = 3`, `p = 1`. This is the OWASP "first
//!    recommended option."
//! 2. If that takes >250 ms per verify on the prod box, fall back
//!    to the current defaults and revisit later.
//!
//! Bumping requires NO migration: existing hashes carry their
//! parameters in the encoded string, so old `m=19456` hashes still
//! verify cleanly even after new ones are minted at `m=65536`. New
//! signups and `reset-password` invocations adopt the new params.
//!
//! ## Why not bcrypt or scrypt?
//!
//! Argon2id won the 2015 Password Hashing Competition. Bcrypt's
//! work factor is 1-D (CPU only) — still safe but doesn't resist
//! GPUs as well as memory-hard schemes. Scrypt is fine but the
//! Rust ecosystem standardized on argon2 (RustCrypto org), so we
//! get the best-audited, most-maintained implementation by picking
//! Argon2.

use argon2::Argon2;
use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};

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
