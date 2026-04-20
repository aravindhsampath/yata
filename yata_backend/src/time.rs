//! Timestamp comparison utilities.
//!
//! Lexical string comparison on ISO8601/RFC3339 values looks correct but
//! breaks down across timezone offsets and fractional-second precision
//! variations (e.g. `2026-04-20T09:15:32.789+00:00` vs `2026-04-20T09:15:32Z`).
//! Always parse before comparing.

use chrono::{DateTime, FixedOffset};

/// Returns `true` iff `server` is strictly later than `client`. Both inputs
/// are expected to be RFC3339 timestamps; if either fails to parse, we fall
/// back to lexical comparison rather than accidentally letting a malformed
/// value overwrite server state.
pub fn is_server_newer(server: &str, client: &str) -> bool {
    match (
        DateTime::<FixedOffset>::parse_from_rfc3339(server),
        DateTime::<FixedOffset>::parse_from_rfc3339(client),
    ) {
        (Ok(s), Ok(c)) => s > c,
        _ => server > client,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_fractional_vs_no_fractional() {
        // Server has fractional seconds, client doesn't — lexical compare
        // would incorrectly flag the client as stale.
        let server = "2026-04-20T09:15:32.789+00:00";
        let client = "2026-04-20T09:15:32+00:00";
        assert!(is_server_newer(server, client));
        // They're semantically the SAME instant with different precision;
        // but server IS strictly newer by 0.789s, so the > is correct.
    }

    #[test]
    fn identical_timestamps_are_not_newer() {
        let t = "2026-04-20T09:15:32+00:00";
        assert!(!is_server_newer(t, t));
    }

    #[test]
    fn different_offsets_still_compare_as_instants() {
        // Same instant expressed two ways — should NOT be newer.
        let server = "2026-04-20T09:15:32+00:00";
        let client = "2026-04-20T11:15:32+02:00";
        assert!(!is_server_newer(server, client));
        assert!(!is_server_newer(client, server));
    }

    #[test]
    fn genuine_newer_server_returns_true() {
        let server = "2026-04-20T09:15:33+00:00";
        let client = "2026-04-20T09:15:32+00:00";
        assert!(is_server_newer(server, client));
    }

    #[test]
    fn date_only_client_falls_back_to_lexical() {
        // Previously-broken case: client sent a date-only string. Lexical
        // compare says server (longer) is newer, which is what we want to
        // preserve as fallback so that malformed input still errs on the
        // side of safety.
        let server = "2026-04-20T09:15:32+00:00";
        let client = "2026-04-20";
        assert!(is_server_newer(server, client));
    }
}
