use std::path::PathBuf;

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    pub url: String,
    pub username: String,
    pub token: String,
    pub expires_at: Option<String>,
}

pub fn config_path() -> Result<PathBuf> {
    let base = dirs::config_dir().ok_or_else(|| anyhow!("no config dir"))?;
    Ok(base.join("yata").join("config.json"))
}

pub fn load() -> Result<Option<Config>> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("read {}", path.display()))?;
    let cfg: Config = serde_json::from_str(&text).context("parse config.json")?;
    Ok(Some(cfg))
}

pub fn save(cfg: &Config) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(cfg)?;
    std::fs::write(&path, text).with_context(|| format!("write {}", path.display()))?;
    // Best-effort 0600 so the token isn't world-readable.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

pub fn clear() -> Result<()> {
    let path = config_path()?;
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

/// Resolve effective config from (CLI args) → env → on-disk config. Any field
/// can be overridden via env: YATA_URL, YATA_USERNAME, YATA_TOKEN.
pub fn effective(disk: Option<Config>) -> Option<Config> {
    let url = std::env::var("YATA_URL").ok().or_else(|| disk.as_ref().map(|c| c.url.clone()));
    let username = std::env::var("YATA_USERNAME").ok().or_else(|| disk.as_ref().map(|c| c.username.clone()));
    let token = std::env::var("YATA_TOKEN").ok().or_else(|| disk.as_ref().map(|c| c.token.clone()));
    let expires_at = disk.as_ref().and_then(|c| c.expires_at.clone());
    match (url, username, token) {
        (Some(url), Some(username), Some(token)) => Some(Config { url, username, token, expires_at }),
        _ => None,
    }
}
