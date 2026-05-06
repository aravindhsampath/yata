//! Observability initialization — currently just the tracing subscriber.
//!
//! Two output formats:
//!
//! - **Pretty** (default): human-readable, suitable for `cargo run`
//!   and `journalctl -u yata` when an operator is debugging live.
//! - **JSON**: structured one-line-per-event. Suitable for production
//!   journald → log-aggregator pipelines (e.g. `journalctl -o json`,
//!   then ship to Loki/CloudWatch/etc).
//!
//! Format is picked by the `YATA_LOG_FORMAT` env var. Anything other
//! than `json` (case-insensitive) gets pretty.
//!
//! Log level is picked by `RUST_LOG`, default `info`. We deliberately
//! reuse the standard `tracing-subscriber` env var rather than
//! inventing `YATA_LOG_LEVEL` — anyone familiar with the Rust
//! ecosystem already knows how to control it.

use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::format::FmtSpan;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Pretty,
    Json,
}

impl Format {
    /// Resolve the format from `YATA_LOG_FORMAT` in the process env.
    pub fn from_env() -> Self {
        Self::from_value(std::env::var("YATA_LOG_FORMAT").unwrap_or_default())
    }

    /// Resolve the format from an arbitrary string. Factored out so
    /// unit tests don't have to touch process-global env vars.
    pub fn from_value(v: impl AsRef<str>) -> Self {
        match v.as_ref().trim().to_lowercase().as_str() {
            "json" => Self::Json,
            _ => Self::Pretty,
        }
    }
}

/// Initialize the global `tracing` subscriber. Idempotent within a
/// process — uses `try_init` so a second call (e.g. test harness
/// running after main, or a unit test invoking it twice) is a no-op
/// rather than a panic. Returns the resolved format so the caller
/// can log the choice for the operator's benefit.
pub fn init() -> Format {
    let format = Format::from_env();
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    match format {
        Format::Json => {
            let _ = tracing_subscriber::fmt()
                .json()
                .with_env_filter(filter)
                .with_span_events(FmtSpan::CLOSE)
                .try_init();
        }
        Format::Pretty => {
            let _ = tracing_subscriber::fmt()
                .pretty()
                .with_env_filter(filter)
                .try_init();
        }
    }
    format
}

#[cfg(test)]
mod tests {
    use super::Format;

    #[test]
    fn empty_value_resolves_to_pretty() {
        assert_eq!(Format::from_value(""), Format::Pretty);
    }

    #[test]
    fn json_lowercase_is_json() {
        assert_eq!(Format::from_value("json"), Format::Json);
    }

    #[test]
    fn json_uppercase_is_json() {
        assert_eq!(Format::from_value("JSON"), Format::Json);
    }

    #[test]
    fn json_with_whitespace_is_json() {
        assert_eq!(Format::from_value(" json \n"), Format::Json);
    }

    #[test]
    fn unknown_value_defaults_to_pretty() {
        assert_eq!(Format::from_value("yaml"), Format::Pretty);
    }

    #[test]
    fn typo_does_not_silently_become_json() {
        // If we ever accept "json5" as JSON, callers will be surprised.
        assert_eq!(Format::from_value("json5"), Format::Pretty);
    }
}
