//! Timestamp comparison utilities.
//!
//! Lexical string comparison on ISO8601/RFC3339 values looks correct but
//! breaks down across timezone offsets and fractional-second precision
//! variations (e.g. `2026-04-20T09:15:32.789+00:00` vs `2026-04-20T09:15:32Z`).
//! Always parse before comparing.

use chrono::{DateTime, FixedOffset};

/// Returns `true` iff `server` is strictly later than `client` at
/// **whole-second precision**.
///
/// Why whole-second: `chrono::Utc::now().to_rfc3339()` on the server
/// emits nanosecond precision (e.g. `…T11:02:37.149064188+00:00`), but
/// iOS's `ISO8601DateFormatter` with `.withInternetDateTime` emits
/// whole-second precision on the way back up (`…T11:02:37Z`). A naive
/// nanosecond comparison makes every single PUT a false 409. Comparing
/// at one-second resolution is forgiving enough for round-trip
/// precision loss while still catching genuine cross-device conflicts
/// (a second device updating the same row takes far longer than 1s).
///
/// If either input fails to parse as RFC3339 we fall back to lexical
/// comparison of the raw strings so malformed input still errs toward
/// safety.
pub fn is_server_newer(server: &str, client: &str) -> bool {
    match (
        DateTime::<FixedOffset>::parse_from_rfc3339(server),
        DateTime::<FixedOffset>::parse_from_rfc3339(client),
    ) {
        (Ok(s), Ok(c)) => s.timestamp() > c.timestamp(),
        _ => server > client,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fractional_within_same_second_is_not_newer() {
        // This is the iOS round-trip precision-loss case: server stored
        // nanosecond precision, client echoes back whole-second. They
        // refer to the same second, so we must NOT flag conflict.
        let server = "2026-04-20T09:15:32.789+00:00";
        let client = "2026-04-20T09:15:32+00:00";
        assert!(!is_server_newer(server, client));
    }

    #[test]
    fn nanosecond_stored_vs_whole_second_client_is_not_newer() {
        // Exact shape that caused the iOS 409-on-every-update bug.
        let server = "2026-04-20T11:02:37.149064188+00:00";
        let client = "2026-04-20T11:02:37Z";
        assert!(!is_server_newer(server, client));
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
