// Stamps `GIT_SHA` and `BUILT_AT` into the binary at compile time so
// `GET /version` can report them without shelling out at runtime.
//
// Both values are read via `env!()` at runtime — see
// `src/handlers/health.rs::version`. If either tool is unavailable
// (no git, no system clock) we fall back to `"unknown"` rather than
// fail the build, because `cargo build` should still succeed inside
// minimal Docker images and inside the source tarball that
// `cargo package` produces (no .git there).

use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let sha = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=GIT_SHA={sha}");

    // RFC3339-ish timestamp without pulling chrono into build-deps.
    // We only need a rough "when was this binary built" stamp; the
    // operator can correlate with deploy logs for anything finer.
    let built_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_else(|_| "0".into());
    println!("cargo:rustc-env=BUILT_AT_EPOCH={built_at}");

    // Re-run when HEAD moves so the SHA stays in sync with the
    // working tree without `cargo clean`.
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs");
}
