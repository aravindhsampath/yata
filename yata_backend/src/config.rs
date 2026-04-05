use std::env;

#[derive(Clone)]
pub struct Config {
    pub secret: String,
    pub db_path: String,
    pub port: u16,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            secret: env::var("YATA_SECRET").expect("YATA_SECRET must be set"),
            db_path: env::var("YATA_DB_PATH").unwrap_or_else(|_| "yata.db".to_string()),
            port: env::var("YATA_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(3000),
        }
    }
}
