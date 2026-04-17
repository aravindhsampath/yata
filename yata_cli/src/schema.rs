//! Token-efficient capability description. Both forms are ~250 tokens.
//! `yata schema`        → terse text (default; readable for LLMs)
//! `yata schema --json` → dense JSON (fewer bytes, structured)

pub const SCHEMA_TEXT: &str = "\
yata — CLI for the YATA todo backend (same REST API the iOS app uses).
Out: compact JSON on stdout, --pretty for humans. Exit: 0 ok / 1 user / 2 api / 3 net.

urgency: green|high=2, yellow|medium=1, red|low=0
date:    YYYY-MM-DD | today | tomorrow | yesterday | next-week
<q>:     UUID or case-insensitive title substring (must match exactly 1;
         0→no_match, >1→ambiguous_match with candidates[]).

Auth: per-user JWT cached at ~/.config/yata/config.json. Run `login` once.
Env overrides: YATA_URL, YATA_USERNAME, YATA_TOKEN.

Commands:
  login          [--url U] [--username N] [--password P]  (prompts if omitted)
  logout
  status                                                   → {url,username,authenticated,server_version,expires_at}
  add <TITLE>    [--urgency=yellow] [--date=today] [--reminder=RFC3339]
  list           [--date=today|all] [--urgency=G|Y|R] [--done] [--limit=25]
  done <q>
  undo <q>                                                 (matches done items; reschedules to today)
  delete <q>                                               (idempotent)
  reschedule <q> --to DATE [--keep-count]
  move <q>       --to green|yellow|red
  stats          [--date=today]                            → {date,active:{green,yellow,red},done}
  repeating list
  raw METHOD PATH [--body JSON]                            METHOD ∈ GET|POST|PUT|DELETE; auth auto-injected
  schema         [--json]

Globals: --pretty, --quiet.
Errors (stderr JSON): {error, code, ...}. Codes:
  missing_config, no_match, ambiguous_match, api_error, network_error,
  unauthorized, validation_error, not_found, conflict.
";

pub const SCHEMA_JSON: &str = r#"{"name":"yata","output":"json-on-stdout; --pretty for humans","exit":{"0":"ok","1":"user","2":"api","3":"net"},"concepts":{"urgency":"green|high=2,yellow|medium=1,red|low=0","date":"YYYY-MM-DD|today|tomorrow|yesterday|next-week","q":"UUID or case-insensitive title substring, must match 1"},"env":["YATA_URL","YATA_USERNAME","YATA_TOKEN"],"commands":{"login":"[--url U][--username N][--password P]","logout":"","status":"","add":"<TITLE> [--urgency=yellow][--date=today][--reminder=RFC3339]","list":"[--date=today|all][--urgency][--done][--limit=25]","done":"<q>","undo":"<q>","delete":"<q>","reschedule":"<q> --to DATE [--keep-count]","move":"<q> --to green|yellow|red","stats":"[--date=today]","repeating list":"","raw":"METHOD PATH [--body JSON]","schema":"[--json]"},"globals":["--pretty","--quiet"],"error_codes":["missing_config","no_match","ambiguous_match","api_error","network_error","unauthorized","validation_error","not_found","conflict"]}"#;
