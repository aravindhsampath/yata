use anyhow::{Context, Result, anyhow, bail};
use reqwest::{Client, Method, StatusCode};
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::config::Config;

pub struct Api {
    pub cfg: Config,
    client: Client,
}

impl Api {
    pub fn new(cfg: Config) -> Result<Self> {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()?;
        Ok(Self { cfg, client })
    }

    pub async fn auth(url: &str, username: &str, password: &str) -> Result<(String, Option<String>)> {
        let client = Client::builder().timeout(std::time::Duration::from_secs(15)).build()?;
        let resp = client
            .post(format!("{}/auth/token", url.trim_end_matches('/')))
            .json(&serde_json::json!({ "username": username, "password": password }))
            .send()
            .await
            .context("auth request failed")?;
        let status = resp.status();
        let body: Value = resp.json().await.context("parse auth response")?;
        if !status.is_success() {
            bail!(
                "auth failed ({}): {}",
                status.as_u16(),
                body.get("error").and_then(|e| e.get("message")).and_then(|m| m.as_str()).unwrap_or("")
            );
        }
        let token = body
            .get("token")
            .and_then(|t| t.as_str())
            .ok_or_else(|| anyhow!("missing token in response"))?
            .to_string();
        let expires_at = body.get("expires_at").and_then(|e| e.as_str()).map(String::from);
        Ok((token, expires_at))
    }

    pub async fn health(&self) -> Result<Value> {
        let resp = self
            .client
            .get(format!("{}/health", self.base()))
            .send()
            .await?;
        Ok(resp.json().await?)
    }

    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        self.request(Method::GET, path, None::<Value>).await
    }

    pub async fn post<T: DeserializeOwned>(&self, path: &str, body: Value) -> Result<T> {
        self.request(Method::POST, path, Some(body)).await
    }

    pub async fn delete(&self, path: &str) -> Result<()> {
        self.request_raw(Method::DELETE, path, None::<Value>).await.map(|_| ())
    }

    /// Raw request for the escape hatch. Returns the parsed JSON body (or null for 204).
    pub async fn raw(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        let method = Method::from_bytes(method.to_uppercase().as_bytes())
            .map_err(|e| anyhow!("invalid method: {e}"))?;
        let text = self.request_raw(method, path, body).await?;
        if text.is_empty() {
            Ok(Value::Null)
        } else {
            Ok(serde_json::from_str(&text).unwrap_or(Value::String(text)))
        }
    }

    async fn request<T: DeserializeOwned, B: serde::Serialize>(
        &self,
        method: Method,
        path: &str,
        body: Option<B>,
    ) -> Result<T> {
        let text = self.request_raw(method, path, body).await?;
        serde_json::from_str(&text).with_context(|| format!("parse response: {text}"))
    }

    async fn request_raw<B: serde::Serialize>(
        &self,
        method: Method,
        path: &str,
        body: Option<B>,
    ) -> Result<String> {
        let url = format!("{}{}", self.base(), path);
        let mut req = self
            .client
            .request(method.clone(), &url)
            .bearer_auth(&self.cfg.token);
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await.with_context(|| format!("{method} {url}"))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if status.is_success() {
            return Ok(text);
        }
        match status {
            StatusCode::UNAUTHORIZED => {
                bail!("401 Unauthorized — run `yata login` to refresh the token");
            }
            StatusCode::NOT_FOUND => bail!("404 Not Found"),
            StatusCode::CONFLICT => bail!("409 Conflict: {text}"),
            _ => bail!("{} {}: {}", status.as_u16(), status.canonical_reason().unwrap_or(""), text),
        }
    }

    fn base(&self) -> String {
        self.cfg.url.trim_end_matches('/').to_string()
    }
}
