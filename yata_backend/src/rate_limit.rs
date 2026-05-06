//! Per-IP rate limiting for `/auth/token`.
//!
//! `argon2` defaults make password verification take ~50ms, which
//! caps a brute-force attacker at ~20 attempts/sec/CPU on a single
//! connection — but at internet bandwidth and with parallelism that
//! still permits hundreds of thousands of attempts per day. This
//! layer slams the door at the request level: a per-IP token bucket
//! returns 429 once an attacker exceeds the burst.
//!
//! Only `/auth/token` is rate-limited. Authenticated routes are
//! covered by the JWT bearer check; rate-limiting them is a separate
//! concern that we don't need yet.
//!
//! Production sees real client IPs through Caddy's
//! `X-Forwarded-For`, so the layer (constructed in `routes.rs`)
//! uses `SmartIpKeyExtractor` which checks `Forwarded` →
//! `X-Forwarded-For` → `X-Real-IP` → connection peer.

/// Knobs for the rate limiter. Defaults match the
/// `hardening_plan.md` decision (D + E): per-IP, 5 attempts per
/// minute, with bursts up to 5.
///
/// Intentionally tiny and `Copy` so it can be passed by value and
/// stored in test harness setup with no Arc plumbing.
#[derive(Debug, Clone, Copy)]
pub struct RateLimitConfig {
    /// Maximum number of requests that can be made in quick
    /// succession before the bucket is empty.
    pub auth_burst: u32,
    /// Seconds between token replenishments. With `auth_burst = 5`
    /// and `auth_per_secs = 12`, the bucket refills at 5 tokens per
    /// minute (1 token / 12 s).
    pub auth_per_secs: u64,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            auth_burst: 5,
            auth_per_secs: 12,
        }
    }
}

impl RateLimitConfig {
    /// A "you shall not pass" config for tests: burst of 2,
    /// replenishes once an hour. Lets a test fire 3 requests
    /// rapidly and assert the third is rejected, without any
    /// real-time sleep.
    pub fn for_test_lockout() -> Self {
        Self {
            auth_burst: 2,
            auth_per_secs: 3600,
        }
    }
}
