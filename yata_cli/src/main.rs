mod api;
mod config;
mod pretty;
mod schema;

use anyhow::{Context, Result, anyhow};
use chrono::{Datelike, Duration, Local, NaiveDate};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use uuid::Uuid;

use api::Api;

#[derive(Parser)]
#[command(
    name = "yata",
    version,
    about = "CLI for the YATA todo backend. Talks to the same REST API the iOS app uses.",
    long_about = "Run `yata schema` to print a machine-readable description of every command (for LLM use)."
)]
struct Cli {
    #[arg(long, global = true, help = "Render output as a human-friendly table instead of JSON.")]
    pretty: bool,

    #[arg(long, global = true, help = "Suppress success output on stdout (errors still go to stderr).")]
    quiet: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Authenticate and cache a JWT for subsequent commands.
    Login {
        #[arg(long)] url: Option<String>,
        #[arg(long)] username: Option<String>,
        #[arg(long)] password: Option<String>,
    },
    /// Delete the cached token and config.
    Logout,
    /// Report config + /health connectivity.
    Status,
    /// Create a todo item.
    Add {
        title: String,
        #[arg(long, default_value = "yellow")] urgency: String,
        #[arg(long, default_value = "today")] date: String,
        #[arg(long)] reminder: Option<String>,
    },
    /// List todos.
    List {
        #[arg(long, default_value = "today")] date: String,
        #[arg(long)] urgency: Option<String>,
        #[arg(long)] done: bool,
        #[arg(long, default_value_t = 25)] limit: i64,
    },
    /// Mark one active item as done. Accepts UUID or title substring.
    Done { id_or_query: String },
    /// Un-mark a done item.
    Undo { id_or_query: String },
    /// Permanently delete an item.
    Delete { id_or_query: String },
    /// Move an item to a different scheduled_date.
    Reschedule {
        id_or_query: String,
        #[arg(long)] to: String,
        #[arg(long)] keep_count: bool,
    },
    /// Change an active item's urgency lane.
    Move {
        id_or_query: String,
        #[arg(long)] to: String,
    },
    /// Priority counts for a date plus today's done total.
    Stats {
        #[arg(long, default_value = "today")] date: String,
    },
    /// Manage repeating rules.
    #[command(subcommand)]
    Repeating(RepeatingCmd),
    /// Escape hatch: call any endpoint directly.
    Raw {
        method: String,
        path: String,
        #[arg(long)] body: Option<String>,
    },
    /// Print a token-efficient capability description for LLMs.
    Schema {
        #[arg(long, help = "Emit JSON form instead of the terse text (slightly more tokens).")]
        json: bool,
    },
}

#[derive(Subcommand)]
enum RepeatingCmd {
    /// List all repeating rules.
    List,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let cli = Cli::parse();
    let exit_code = match run(cli).await {
        Ok(()) => 0,
        Err(e) => {
            emit_error(&e);
            exit_code_for(&e)
        }
    };
    std::process::exit(exit_code);
}

async fn run(cli: Cli) -> Result<()> {
    let pretty = cli.pretty;
    let quiet = cli.quiet;
    match cli.command {
        Command::Schema { json } => {
            if json {
                println!("{}", schema::SCHEMA_JSON);
            } else {
                print!("{}", schema::SCHEMA_TEXT);
            }
            Ok(())
        }
        Command::Login { url, username, password } => cmd_login(url, username, password, quiet).await,
        Command::Logout => cmd_logout(quiet),
        Command::Status => cmd_status(pretty).await,
        other => {
            // All remaining commands need auth.
            let cfg = config::effective(config::load()?).ok_or_else(|| Tagged::new(
                "missing_config",
                "No config found. Run `yata login` or set YATA_URL / YATA_USERNAME / YATA_TOKEN.",
            ))?;
            let api = Api::new(cfg)?;
            match other {
                Command::Add { title, urgency, date, reminder } => cmd_add(&api, title, urgency, date, reminder, pretty).await,
                Command::List { date, urgency, done, limit } => cmd_list(&api, date, urgency, done, limit, pretty).await,
                Command::Done { id_or_query } => cmd_done(&api, id_or_query, pretty).await,
                Command::Undo { id_or_query } => cmd_undo(&api, id_or_query, pretty).await,
                Command::Delete { id_or_query } => cmd_delete(&api, id_or_query, quiet).await,
                Command::Reschedule { id_or_query, to, keep_count } => cmd_reschedule(&api, id_or_query, to, keep_count, pretty).await,
                Command::Move { id_or_query, to } => cmd_move(&api, id_or_query, to, pretty).await,
                Command::Stats { date } => cmd_stats(&api, date, pretty).await,
                Command::Repeating(sub) => match sub {
                    RepeatingCmd::List => cmd_repeating_list(&api, pretty).await,
                },
                Command::Raw { method, path, body } => cmd_raw(&api, method, path, body).await,
                Command::Schema { .. } | Command::Login { .. } | Command::Logout | Command::Status => unreachable!(),
            }
        }
    }
}

// ─── login / logout / status ───────────────────────────────────────────────

async fn cmd_login(url: Option<String>, username: Option<String>, password: Option<String>, quiet: bool) -> Result<()> {
    let url = url.or_else(|| std::env::var("YATA_URL").ok()).or_else(|| prompt("Server URL: ").ok())
        .ok_or_else(|| anyhow!("url required"))?;
    let username = username.or_else(|| std::env::var("YATA_USERNAME").ok()).or_else(|| prompt("Username: ").ok())
        .ok_or_else(|| anyhow!("username required"))?;
    let password = match password {
        Some(p) => p,
        None => std::env::var("YATA_PASSWORD").or_else(|_| rpassword::prompt_password("Password: "))?,
    };
    let (token, expires_at) = Api::auth(&url, &username, &password).await?;
    let cfg = config::Config { url: url.clone(), username: username.clone(), token, expires_at };
    config::save(&cfg)?;
    if !quiet {
        println!("{}", json!({ "ok": true, "url": url, "username": username }));
    }
    Ok(())
}

fn cmd_logout(quiet: bool) -> Result<()> {
    config::clear()?;
    if !quiet {
        println!("{}", json!({ "ok": true }));
    }
    Ok(())
}

async fn cmd_status(pretty: bool) -> Result<()> {
    let disk = config::load()?;
    let cfg = config::effective(disk);
    let Some(cfg) = cfg else {
        let out = json!({ "authenticated": false, "reason": "no config; run `yata login`" });
        emit(&out, pretty, |_| println!("Not logged in. Run `yata login`."));
        return Ok(());
    };
    let api = Api::new(cfg.clone())?;
    let health = api.health().await.ok();
    let out = json!({
        "url": cfg.url,
        "username": cfg.username,
        "authenticated": health.is_some(),
        "server_version": health.as_ref().and_then(|h| h.get("version").cloned()),
        "expires_at": cfg.expires_at,
    });
    emit(&out, pretty, |v| {
        println!("server:    {}", v["url"].as_str().unwrap_or(""));
        println!("user:      {}", v["username"].as_str().unwrap_or(""));
        println!("reachable: {}", v["authenticated"].as_bool().unwrap_or(false));
        if let Some(exp) = v["expires_at"].as_str() { println!("expires:   {exp}"); }
    });
    Ok(())
}

// ─── add / list ────────────────────────────────────────────────────────────

async fn cmd_add(api: &Api, title: String, urgency: String, date: String, reminder: Option<String>, pretty: bool) -> Result<()> {
    let priority = parse_urgency(&urgency)?;
    let scheduled_date = parse_date(&date)?;
    let body = json!({
        "id": Uuid::new_v4().to_string(),
        "title": title,
        "priority": priority,
        "scheduled_date": scheduled_date,
        "reminder_date": reminder,
        "sort_order": 0,
        "source_repeating_id": null,
        "source_repeating_rule_name": null,
    });
    let created: Value = api.post("/items", body).await?;
    emit(&created, pretty, |v| pretty::print_items(std::slice::from_ref(v)));
    Ok(())
}

async fn cmd_list(api: &Api, date: String, urgency: Option<String>, done: bool, limit: i64, pretty: bool) -> Result<()> {
    let items: Vec<Value> = if done {
        let resp: Value = api.get(&format!("/items/done?limit={limit}&offset=0")).await?;
        resp.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default()
    } else {
        fetch_active(api, &date, urgency.as_deref()).await?
    };
    let out = json!({ "items": items, "count": items.len() });
    emit(&out, pretty, |v| pretty::print_items(v["items"].as_array().unwrap_or(&vec![])));
    Ok(())
}

async fn fetch_active(api: &Api, date: &str, urgency: Option<&str>) -> Result<Vec<Value>> {
    if date == "all" {
        // Fetch all three lanes for today by default when "all" is used without date;
        // full cross-date scan isn't supported by the API, so we only cover today.
        // Caller can issue multiple `yata list --date ...` commands for a wider window.
        let d = parse_date("today")?;
        return collect_lanes(api, &d, urgency).await;
    }
    let d = parse_date(date)?;
    collect_lanes(api, &d, urgency).await
}

async fn collect_lanes(api: &Api, date: &str, urgency: Option<&str>) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    let lanes: Vec<i64> = match urgency {
        Some(u) => vec![parse_urgency(u)?],
        None => vec![2, 1, 0],
    };
    for p in lanes {
        let resp: Value = api.get(&format!("/items?date={date}&priority={p}")).await?;
        if let Some(arr) = resp.get("items").and_then(|v| v.as_array()) {
            out.extend(arr.iter().cloned());
        }
    }
    Ok(out)
}

// ─── done / undo / delete / reschedule / move ─────────────────────────────

async fn cmd_done(api: &Api, q: String, pretty: bool) -> Result<()> {
    let id = resolve_active_id(api, &q).await?;
    let updated: Value = api.post(&format!("/items/{id}/done"), json!({})).await?;
    emit(&updated, pretty, |v| pretty::print_items(std::slice::from_ref(v)));
    Ok(())
}

async fn cmd_undo(api: &Api, q: String, pretty: bool) -> Result<()> {
    let id = resolve_done_id(api, &q).await?;
    let body = json!({ "scheduled_date": parse_date("today")? });
    let updated: Value = api.post(&format!("/items/{id}/undone"), body).await?;
    emit(&updated, pretty, |v| pretty::print_items(std::slice::from_ref(v)));
    Ok(())
}

async fn cmd_delete(api: &Api, q: String, quiet: bool) -> Result<()> {
    let id = resolve_any_id(api, &q).await?;
    api.delete(&format!("/items/{id}")).await?;
    if !quiet {
        println!("{}", json!({ "ok": true, "deleted": id.to_string() }));
    }
    Ok(())
}

async fn cmd_reschedule(api: &Api, q: String, to: String, keep_count: bool, pretty: bool) -> Result<()> {
    let id = resolve_active_id(api, &q).await?;
    let body = json!({ "to_date": parse_date(&to)?, "reset_count": !keep_count });
    let updated: Value = api.post(&format!("/items/{id}/reschedule"), body).await?;
    emit(&updated, pretty, |v| pretty::print_items(std::slice::from_ref(v)));
    Ok(())
}

async fn cmd_move(api: &Api, q: String, to: String, pretty: bool) -> Result<()> {
    let id = resolve_active_id(api, &q).await?;
    let priority = parse_urgency(&to)?;
    // Move to the end of the target lane (at_index=0 pushes to top; pick top-of-lane
    // for visibility, consistent with iOS reorder defaults).
    let body = json!({ "to_priority": priority, "at_index": 0 });
    let updated: Value = api.post(&format!("/items/{id}/move"), body).await?;
    emit(&updated, pretty, |v| pretty::print_items(std::slice::from_ref(v)));
    Ok(())
}

// ─── stats / repeating / raw ───────────────────────────────────────────────

async fn cmd_stats(api: &Api, date: String, pretty: bool) -> Result<()> {
    let d = parse_date(&date)?;
    let counts: Value = api.get(&format!("/stats/counts?dates={d}")).await?;
    let done: Value = api.get(&format!("/stats/done-count?date={d}")).await?;
    let lane = counts.get("counts").and_then(|c| c.get(&d)).cloned().unwrap_or(json!({}));
    let out = json!({
        "date": d,
        "active": {
            "red":    lane.get("0").and_then(|v| v.as_i64()).unwrap_or(0),
            "yellow": lane.get("1").and_then(|v| v.as_i64()).unwrap_or(0),
            "green":  lane.get("2").and_then(|v| v.as_i64()).unwrap_or(0),
        },
        "done": done.get("count").and_then(|v| v.as_i64()).unwrap_or(0),
    });
    emit(&out, pretty, |v| {
        println!("{}", v["date"].as_str().unwrap_or(""));
        println!("  🟢 green  {}", v["active"]["green"]);
        println!("  🟡 yellow {}", v["active"]["yellow"]);
        println!("  🔴 red    {}", v["active"]["red"]);
        println!("  ✓ done   {}", v["done"]);
    });
    Ok(())
}

async fn cmd_repeating_list(api: &Api, pretty: bool) -> Result<()> {
    let resp: Value = api.get("/repeating").await?;
    let items = resp.get("items").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let out = json!({ "items": items, "count": items.len() });
    emit(&out, pretty, |v| pretty::print_repeating(v["items"].as_array().unwrap_or(&vec![])));
    Ok(())
}

async fn cmd_raw(api: &Api, method: String, path: String, body: Option<String>) -> Result<()> {
    let body_json = match body {
        Some(s) => Some(serde_json::from_str(&s).context("--body must be valid JSON")?),
        None => None,
    };
    let resp = api.raw(&method, &path, body_json).await?;
    println!("{resp}");
    Ok(())
}

// ─── Query resolution: UUID or title substring ─────────────────────────────

async fn resolve_any_id(api: &Api, q: &str) -> Result<Uuid> {
    if let Ok(uuid) = Uuid::parse_str(q) {
        return Ok(uuid);
    }
    // Search across active + done on today's date first, then widen.
    let mut pool: Vec<Value> = Vec::new();
    let today = parse_date("today")?;
    for p in [2, 1, 0] {
        let r: Value = api.get(&format!("/items?date={today}&priority={p}")).await?;
        if let Some(arr) = r.get("items").and_then(|v| v.as_array()) { pool.extend(arr.iter().cloned()); }
    }
    let done: Value = api.get("/items/done?limit=100&offset=0").await?;
    if let Some(arr) = done.get("items").and_then(|v| v.as_array()) { pool.extend(arr.iter().cloned()); }
    match_exactly_one(&pool, q)
}

async fn resolve_active_id(api: &Api, q: &str) -> Result<Uuid> {
    if let Ok(uuid) = Uuid::parse_str(q) { return Ok(uuid); }
    let today = parse_date("today")?;
    let mut pool: Vec<Value> = Vec::new();
    for p in [2, 1, 0] {
        let r: Value = api.get(&format!("/items?date={today}&priority={p}")).await?;
        if let Some(arr) = r.get("items").and_then(|v| v.as_array()) { pool.extend(arr.iter().cloned()); }
    }
    match_exactly_one(&pool, q)
}

async fn resolve_done_id(api: &Api, q: &str) -> Result<Uuid> {
    if let Ok(uuid) = Uuid::parse_str(q) { return Ok(uuid); }
    let done: Value = api.get("/items/done?limit=100&offset=0").await?;
    let pool: Vec<Value> = done.get("items").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    match_exactly_one(&pool, q)
}

fn match_exactly_one(pool: &[Value], q: &str) -> Result<Uuid> {
    let needle = q.to_lowercase();
    // Dedup by id (the same item can appear in both active and done pools
    // when its scheduled_date is today and it's also marked done).
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let matches: Vec<&Value> = pool
        .iter()
        .filter(|it| {
            let title_match = it
                .get("title")
                .and_then(|t| t.as_str())
                .map(|s| s.to_lowercase().contains(&needle))
                .unwrap_or(false);
            if !title_match { return false; }
            if let Some(id) = it.get("id").and_then(|v| v.as_str()) {
                seen.insert(id.to_string())
            } else {
                true
            }
        })
        .collect();
    match matches.len() {
        0 => Err(Tagged::new("no_match", &format!("no item matches \"{q}\"")).into()),
        1 => {
            let id = matches[0].get("id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("match has no id"))?;
            Ok(Uuid::parse_str(id)?)
        }
        n => {
            let candidates: Vec<Value> = matches.iter().map(|m| json!({
                "id": m.get("id"),
                "title": m.get("title"),
                "scheduled_date": m.get("scheduled_date"),
            })).collect();
            let err = Tagged::with_context(
                "ambiguous_match",
                &format!("{n} items match \"{q}\"; refine the query or pass the UUID"),
                json!({ "matches": candidates }),
            );
            Err(err.into())
        }
    }
}

// ─── Parsing helpers ───────────────────────────────────────────────────────

fn parse_urgency(s: &str) -> Result<i64> {
    match s.to_lowercase().as_str() {
        "red" | "low" => Ok(0),
        "yellow" | "medium" | "med" => Ok(1),
        "green" | "high" => Ok(2),
        other => Err(Tagged::new("validation_error", &format!("unknown urgency: {other}")).into()),
    }
}

fn parse_date(s: &str) -> Result<String> {
    let today = Local::now().date_naive();
    let d = match s {
        "today" => today,
        "tomorrow" => today + Duration::days(1),
        "yesterday" => today - Duration::days(1),
        "next-week" | "nextweek" => today + Duration::days(7),
        raw => NaiveDate::parse_from_str(raw, "%Y-%m-%d")
            .map_err(|_| Tagged::new("validation_error", &format!("bad date: {raw} (use YYYY-MM-DD or today/tomorrow/yesterday/next-week)")))?,
    };
    Ok(format!("{:04}-{:02}-{:02}", d.year(), d.month(), d.day()))
}

fn prompt(msg: &str) -> Result<String> {
    use std::io::Write;
    print!("{msg}");
    std::io::stdout().flush().ok();
    let mut s = String::new();
    std::io::stdin().read_line(&mut s)?;
    Ok(s.trim().to_string())
}

// ─── Output + error helpers ────────────────────────────────────────────────

fn emit<F: FnOnce(&Value)>(val: &Value, pretty: bool, human: F) {
    if pretty {
        human(val);
    } else {
        println!("{val}");
    }
}

/// An error that carries a stable machine-readable tag + optional JSON context.
#[derive(Debug)]
struct Tagged {
    code: &'static str,
    message: String,
    context: Option<Value>,
}

impl Tagged {
    fn new(code: &'static str, message: &str) -> Self {
        Self { code, message: message.to_string(), context: None }
    }
    fn with_context(code: &'static str, message: &str, ctx: Value) -> Self {
        Self { code, message: message.to_string(), context: Some(ctx) }
    }
}

impl std::fmt::Display for Tagged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for Tagged {}

fn emit_error(e: &anyhow::Error) {
    let mut obj = serde_json::Map::new();
    if let Some(t) = e.downcast_ref::<Tagged>() {
        obj.insert("error".into(), json!(t.message));
        obj.insert("code".into(), json!(t.code));
        if let Some(ctx) = &t.context {
            if let Some(map) = ctx.as_object() {
                for (k, v) in map { obj.insert(k.clone(), v.clone()); }
            }
        }
    } else {
        obj.insert("error".into(), json!(e.to_string()));
        obj.insert("code".into(), json!(classify(&e.to_string())));
    }
    eprintln!("{}", Value::Object(obj));
}

fn classify(msg: &str) -> &'static str {
    let m = msg.to_lowercase();
    if m.contains("unauthorized") || m.contains("401") { "unauthorized" }
    else if m.contains("404") || m.contains("not found") { "not_found" }
    else if m.contains("409") || m.contains("conflict") { "conflict" }
    else if m.contains("422") || m.contains("validation") { "validation_error" }
    else if m.contains("network") || m.contains("connect") || m.contains("dns") { "network_error" }
    else { "api_error" }
}

fn exit_code_for(e: &anyhow::Error) -> i32 {
    if let Some(t) = e.downcast_ref::<Tagged>() {
        return match t.code {
            "missing_config" | "network_error" => 3,
            "no_match" | "ambiguous_match" | "validation_error" => 1,
            _ => 2,
        };
    }
    let c = classify(&e.to_string());
    match c {
        "network_error" => 3,
        "validation_error" => 1,
        _ => 2,
    }
}

