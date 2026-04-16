use std::env;

#[derive(Clone)]
pub struct Config {
    /// Server-side signing key for JWTs. Must be set; should be a long
    /// random secret (e.g. `openssl rand -hex 32`). This is NOT a user
    /// password — users authenticate with username+password and receive
    /// JWTs signed with this key.
    pub jwt_secret: String,
    pub db_path: String,
    pub port: u16,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            jwt_secret: env::var("YATA_JWT_SECRET").expect("YATA_JWT_SECRET must be set"),
            db_path: env::var("YATA_DB_PATH").unwrap_or_else(|_| "yata.db".to_string()),
            port: env::var("YATA_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(3000),
        }
    }
}
