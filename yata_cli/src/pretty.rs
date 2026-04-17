//! Human-friendly formatting for --pretty. Kept small: no tabular deps.

use serde_json::Value;

pub fn print_items(items: &[Value]) {
    if items.is_empty() {
        println!("(no items)");
        return;
    }
    for item in items {
        let title = item.get("title").and_then(|v| v.as_str()).unwrap_or("?");
        let priority = item.get("priority").and_then(|v| v.as_i64()).unwrap_or(1);
        let urgency = match priority {
            2 => "🟢",
            1 => "🟡",
            0 => "🔴",
            _ => "·",
        };
        let id = item.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let short = id.get(0..8).unwrap_or(id);
        let done = item.get("is_done").and_then(|v| v.as_bool()).unwrap_or(false);
        let check = if done { "✓" } else { " " };
        let scheduled = item.get("scheduled_date").and_then(|v| v.as_str()).unwrap_or("");
        let reminder = item
            .get("reminder_date")
            .and_then(|v| v.as_str())
            .map(|s| format!(" ⏰ {s}"))
            .unwrap_or_default();
        println!("{check} {urgency}  {short}  {title}  ({scheduled}){reminder}");
    }
}

pub fn print_repeating(items: &[Value]) {
    if items.is_empty() {
        println!("(no rules)");
        return;
    }
    for item in items {
        let id = item.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let short = id.get(0..8).unwrap_or(id);
        let title = item.get("title").and_then(|v| v.as_str()).unwrap_or("?");
        let freq = item.get("frequency").and_then(|v| v.as_i64()).unwrap_or(0);
        let freq_name = match freq {
            0 => "daily",
            1 => "weekday",
            2 => "weekly",
            3 => "monthly",
            4 => "yearly",
            _ => "?",
        };
        println!("↻ {short}  {title}  [{freq_name}]");
    }
}
