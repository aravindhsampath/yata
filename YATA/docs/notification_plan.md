# YATA Notification System — Design Plan

## Design Philosophy

YATA's notifications must respect the ADHD brain. Generic reminders ("Don't forget: Call roof guy") create guilt without momentum. They demand a decision — *do I do this now?* — which is the exact cognitive bottleneck ADHD makes hardest. Every notification YATA sends must reduce activation energy, not add to it.

Three rules govern every notification:

1. **If it's not actionable right now, don't send it.** A reminder for a task the user can't act on is noise. Noise trains the brain to dismiss.
2. **Make starting feel already begun.** The hardest part of any task for an ADHD mind is the transition from not-doing to doing. The notification should bridge that gap.
3. **Respect the dismiss.** If a user dismisses a notification, that's signal. Repeating the same notification louder is how you get muted permanently.

---

## Current State

What exists today:

- `TodoItem.reminderDate: Date?` — stored and persisted in SwiftData
- `ReminderPickerSheet` — date/time picker UI (graphical date + wheel time)
- `AddEditSheet` integration — set/remove reminders on items
- Bell icon indicators on pills when a reminder is set
- No `UserNotifications` framework usage anywhere
- No permission request, no scheduling, no notification categories
- `RepeatingItem` has no reminder field — materialized occurrences get `reminderDate = nil`

---

## Phase 1: Foundation

The minimum viable notification system. No AI, no behavioral adaptation. Just reliable, actionable local notifications that respect the user.

### 1.1 Permission Flow

**When to ask:** NOT on first launch. Ask *in context* — the first time the user taps "Add Reminder" in the AddEditSheet.

**Flow:**

```
User taps "Add Reminder"
  |
  +-- Permission not yet requested?
  |     |
  |     +-- Show pre-permission sheet:
  |     |     Title: "Reminders need notifications"
  |     |     Body:  "YATA will send a notification at the time you choose.
  |     |             You can mark tasks done or snooze directly from
  |     |             the notification — no need to open the app."
  |     |     [Enable Notifications]  [Not Now]
  |     |
  |     +-- User taps "Enable" → requestAuthorization(options: [.alert, .sound, .badge])
  |     +-- User taps "Not Now" → still allow setting reminderDate (for in-app use),
  |           show subtle inline note: "Notifications are off — you'll only see
  |           reminders inside the app"
  |
  +-- Permission previously denied?
  |     |
  |     +-- Show inline banner in ReminderPickerSheet:
  |           "Notifications are turned off. You can enable them in Settings."
  |           [Open Settings] — deep-links to app notification settings
  |           Do NOT nag. Show once per session, remember dismissal.
  |
  +-- Permission granted → proceed normally
```

**Key detail:** The reminder date is always stored regardless of notification permission. The date drives in-app indicators (bell icon, potential in-app alerts). Push notifications are a bonus layer on top, not a requirement.

### 1.2 Notification Content & Categories

Every notification must have **exactly 3 actions** — more creates decision paralysis, fewer feels limiting.

#### Category: `TASK_REMINDER`

Triggered when `reminderDate` arrives.

| Element | Content |
|---------|---------|
| **Title** | Task title verbatim — e.g., "Call roof guy" |
| **Subtitle** | Priority context — "Now priority" / "Soon priority" |
| **Body** | Time context — "Scheduled for today" or "Overdue by 2 days" |
| **Sound** | Default system (Phase 2 will differentiate by priority) |

**Actions:**

| Action | Label | Behavior | Destructive? |
|--------|-------|----------|-------------|
| `MARK_DONE` | "Done" | Background — marks item complete, removes from active lists | No |
| `SNOOZE_30` | "30 min" | Background — reschedules notification +30 min | No |
| `TOMORROW` | "Tomorrow" | Background — reschedules item to tomorrow, clears notification | No |

**Default action (tap notification body):** Opens app, scrolls to the item's priority container on the relevant date.

#### Category: `OVERDUE_NUDGE` (Phase 1b)

Triggered for items that have been rescheduled 3+ times (the `rescheduleCount` field already tracks this).

| Element | Content |
|---------|---------|
| **Title** | Task title |
| **Subtitle** | "Rescheduled {n} times" |
| **Body** | Gentle reframe — "5 minutes is enough to start" |

Same 3 actions as `TASK_REMINDER`.

### 1.3 Notification Scheduling Engine

A `NotificationScheduler` service, called from the repository layer whenever a relevant state change occurs.

#### Scheduling triggers:

| Event | Action |
|-------|--------|
| `reminderDate` set on new/edited item | Schedule `UNNotificationRequest` with `UNCalendarNotificationTrigger` |
| `reminderDate` changed | Remove old request, schedule new one |
| `reminderDate` cleared | Remove request |
| Item marked done | Remove request |
| Item deleted | Remove request |
| Item rescheduled to tomorrow | Remove old, schedule new if `reminderDate` was relative to `scheduledDate` |
| Snooze action from notification | Schedule new request at `now + 30 min` (or chosen interval) |
| Tomorrow action from notification | Call `rescheduleToTomorrow`, schedule new for tomorrow at same time-of-day |

#### Identifier scheme:

```
Notification ID = "yata-reminder-{todoItem.id.uuidString}"
```

Single notification per item. Re-scheduling always replaces, never stacks.

#### Implementation location:

```
NotificationScheduler (new file)
  ├── scheduleReminder(for item: TodoItem)
  ├── cancelReminder(for itemID: UUID)
  ├── cancelAllReminders()
  ├── rescheduleSnooze(itemID: UUID, minutes: Int)
  └── syncAllReminders()  // bulk reconciliation on app launch
```

Called from `HomeViewModel` (or repository) — not from views.

#### App launch reconciliation:

On every app launch, `syncAllReminders()` runs:

1. Fetch all non-done TodoItems with `reminderDate != nil` and `reminderDate > now`
2. Fetch all pending `UNNotificationRequest`s
3. Diff — schedule missing, cancel stale
4. This handles edge cases: item deleted while app was killed, date passed while offline, etc.

### 1.4 Badge Management

- Badge count = number of overdue reminders (reminderDate < now, item not done)
- Updated on every `loadAll()` and on notification action callbacks
- Cleared when user opens the app (`applicationDidBecomeActive`)

### 1.5 Notification Response Handling

Requires a `UNUserNotificationCenterDelegate` — set up in `YATAApp` via an `AppDelegate` adapter:

```
@UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
```

The delegate's `userNotificationCenter(_:didReceive:)` parses the action identifier:

| Action ID | Handler |
|-----------|---------|
| `MARK_DONE` | Look up item by UUID from notification ID → `repository.markDone(item)` |
| `SNOOZE_30` | `scheduler.rescheduleSnooze(itemID, minutes: 30)` |
| `TOMORROW` | `repository.rescheduleToTomorrow(item)` |
| Default (tap) | Set `selectedDate` to item's date, navigate to home |

All handlers operate on the repository directly — they don't need the ViewModel since the app may be suspended.

### 1.6 Repeating Items & Reminders

Add `reminderOffset: TimeInterval?` to `RepeatingItem`:

- Stores the offset from `scheduledTime` (e.g., "remind me 30 min before" = -1800)
- When `materializeRepeatingItems()` creates a `TodoItem`, it computes:
  `todoItem.reminderDate = todoItem.scheduledDate + repeatingItem.scheduledTime.timeOfDay + reminderOffset`
- This way each occurrence gets its own concrete reminder, automatically scheduled

---

## Phase 2: Adaptive Behavior

Build on Phase 1's foundation. The system starts learning from the user.

### 2.1 Morning Digest

A single notification at a user-chosen time (default: 8:00 AM, configurable in Settings).

| Element | Content |
|---------|---------|
| **Title** | "Today: {count} tasks" |
| **Body** | Top priority item name — "Starting with: {highest priority item}" |

**Actions:** "View" (opens app) / "Snooze 1h" / "Skip Today"

**Rules:**
- Only sent on days with tasks
- Not sent if the user already opened the app that morning
- Not sent on weekends unless the user has weekend tasks (inferred from history)

**ADHD rationale:** A morning overview reduces the anxiety of "what do I need to do today?" — the Zeigarnik effect means unacknowledged tasks create background cognitive load. One structured overview discharges that tension.

### 2.2 Smart Snooze

Replace fixed "30 min" with contextual intervals:

- **Morning (before noon):** "After lunch" (snooze to 1:00 PM)
- **Afternoon:** "End of day" (snooze to 5:00 PM)
- **Evening:** "Tomorrow morning" (snooze to next day 9:00 AM)
- **Always available:** "Pick a time" (opens app's ReminderPickerSheet)

The interval names use natural language, not minutes. This matches how ADHD brains think about time — in blocks and transitions, not precise durations.

### 2.3 Notification Fatigue Detection

Track in `UserDefaults` (lightweight, no SwiftData needed):

```
notification_dismiss_count: Int        // incremented on dismiss without action
notification_action_count: Int         // incremented on any action taken
last_action_date: Date
consecutive_dismisses: Int             // reset on any action
```

**Throttling rules:**

| Signal | Response |
|--------|----------|
| 3 consecutive dismisses | Reduce to 1 notification per day (morning digest only) |
| 5 consecutive dismisses | Pause all notifications for 48h, then resume with morning digest |
| User takes action | Reset consecutive counter, restore normal frequency |
| No actions for 7 days | Stop non-digest notifications until user manually sets a new reminder |

**ADHD rationale:** Notification fatigue is the #1 reason ADHD users disable notifications entirely. By self-throttling, YATA avoids getting muted at the system level — which is irreversible without the user remembering to go to Settings.

### 2.4 Priority-Differentiated Delivery

| Priority | Sound | Interruption Level |
|----------|-------|-------------------|
| Now (high) | Default | `.timeSensitive` — breaks through Focus modes |
| Soon (medium) | Soft tone | `.active` — normal delivery |
| Later (low) | Silent | `.passive` — delivered quietly, no sound/vibration |

This maps directly to how urgently an ADHD brain needs the interruption. Low-priority items should never break flow state.

### 2.5 Overdue Escalation with Reframing

When a task has been rescheduled 3+ times, the notification changes its approach.

**Escalation ladder:**

| Reschedule Count | Notification Body |
|-----------------|-------------------|
| 3 | "This keeps sliding. Could you do just the first step?" |
| 5 | "What's blocking this? Tap to break it into smaller pieces." |
| 7+ | "This has been on your list for a while. Still relevant? [Keep / Drop]" |

**ADHD rationale:** Repeated reminders for the same task are the textbook definition of guilt-inducing noise. Instead:
- At 3: reduce the ask (lower activation energy)
- At 5: surface the blocker (often ADHD avoidance is about task ambiguity, not laziness)
- At 7+: offer an exit. Sometimes the most productive thing is admitting a task doesn't matter anymore. Letting go of phantom obligations reduces cognitive load.

---

## Phase 3: AI-Powered Notifications (Future Roadmap)

This phase requires on-device or API-based LLM inference. The foundation from Phase 1-2 must be designed to accommodate it, even though implementation is later.

### 3.1 Task Text Understanding

Parse the task title to extract actionable metadata:

| Input | Extracted |
|-------|-----------|
| "Call Stefan about roof" | Contact: Stefan, Action: phone call |
| "Book flights to Berlin" | Action: web search, Keyword: flights Berlin |
| "Send invoice to client" | Action: email/share |
| "Buy milk and eggs" | Category: shopping, Items: milk, eggs |
| "Review PR #42" | Action: open URL (if GitHub integration exists) |

**Foundation requirement:** `TodoItem` needs an optional `parsedMetadata: Data?` field (JSON blob) — added in Phase 3, but the SwiftData model versioning should be planned for now.

### 3.2 Activation-Energy-Reducing Rewrites

The notification body gets rewritten to make the task feel already begun:

| Original Task | Standard Notification | AI-Rewritten |
|--------------|----------------------|-------------|
| "Call roof guy" | "Reminder: Call roof guy" | "Call Stefan about the roof — tap to dial (555) 123-4567" |
| "Write quarterly report" | "Reminder: Write quarterly report" | "Open the doc and write just the intro paragraph. 10 min max." |
| "Schedule dentist appointment" | "Reminder: Schedule dentist" | "Dr. Miller's office: (555) 987-6543. Morning slots are usually open." |
| "Fix bike tire" | "Reminder: Fix bike tire" | "YouTube: 'fix bike tire' is a 4-minute video. Grab the pump." |

**ADHD rationale — Implementation Intentions (Gollwitzer, 1999):**
Research shows that forming "when-then" plans ("when X happens, I will do Y") dramatically increases follow-through for people with executive function challenges. AI rewrites transform vague tasks into concrete first-actions, effectively creating an implementation intention on the user's behalf.

**ADHD rationale — Zeigarnik Effect:**
The brain holds unfinished tasks in working memory, creating tension. But it treats "tasks that have been started" differently — they create *drive to complete* rather than *dread of starting*. By framing the notification as if the task is already underway ("Open the doc and write just the intro"), the AI exploits this effect.

### 3.3 Behavioral Pattern Learning

Over time, build a lightweight local model of user behavior:

| Pattern | Inference | Notification Adjustment |
|---------|-----------|------------------------|
| User completes "Now" tasks mostly before 10 AM | Morning person for high-priority | Schedule Now reminders for 8-9 AM window |
| User never acts on evening notifications | Evening = wind-down time | Stop sending after 7 PM, batch to next morning |
| User snoozes "call" tasks 4x then completes | Phone anxiety (common ADHD) | After 2nd snooze: "Want to text instead of call?" |
| User completes tasks within 5 min of opening app | Momentum-driven | Send digest, not individual reminders |
| Fridays: low completion rate | End-of-week executive function depletion | Move Friday reminders to Monday morning |

**Storage:** Local-only. Privacy-first. A simple SQLite table of (action, timestamp, item_priority, outcome). No cloud sync.

### 3.4 Smart Context Injection

If the user grants calendar access (separate permission, asked only when relevant):

| Calendar Signal | Notification Adjustment |
|----------------|------------------------|
| 15-min gap between meetings | "You have 15 min free — enough time for: {short task}" |
| No meetings until noon | "Clear morning — good time for {deep work task}" |
| Meeting with "Stefan" at 2 PM | "Your call with Stefan is at 2 — that roof question too?" |

**ADHD rationale — Time Blindness:**
ADHD brains struggle with estimating how much time they have and how long tasks take. Injecting calendar context gives them the "time container" they can't intuit — "you have 15 minutes" is actionable in a way "sometime today" never is.

---

## Technical Architecture

### Component Diagram

```
YATAApp
  └── AppDelegate (UIApplicationDelegateAdaptor)
        └── UNUserNotificationCenterDelegate
              └── NotificationActionHandler
                    └── TodoRepository (direct DB access for background actions)

HomeViewModel
  └── calls NotificationScheduler on state changes

NotificationScheduler (stateless service)
  ├── scheduleReminder(for: TodoItem)
  ├── cancelReminder(for: UUID)
  ├── rescheduleSnooze(itemID: UUID, interval: SnoozeInterval)
  ├── syncAllReminders()              // launch reconciliation
  └── scheduleMorningDigest()          // Phase 2

NotificationPermissionManager (ObservableObject)
  ├── authorizationStatus: UNAuthorizationStatus
  ├── requestPermission() async -> Bool
  └── openSettings()

Phase 3 additions:
  TaskTextParser
    └── parse(title: String) -> TaskMetadata
  NotificationRewriter
    └── rewrite(task: TodoItem, metadata: TaskMetadata) -> UNNotificationContent
  BehaviorTracker
    └── record(action: NotificationAction, item: TodoItem)
    └── suggestTiming(for: Priority) -> Date
```

### Data Flow for Scheduling

```
User sets reminderDate in AddEditSheet
  → AddEditSheet calls onSave(title, reminderDate)
  → HomeViewModel.addItem() or .updateItem()
  → Repository persists TodoItem
  → HomeViewModel calls NotificationScheduler.scheduleReminder(item)
  → Scheduler checks permission:
      - Granted → UNUserNotificationCenter.add(request)
      - Denied  → no-op (in-app indicators still work)
```

### Data Flow for Notification Actions

```
User taps "Done" on notification
  → UNUserNotificationCenterDelegate.didReceive(response)
  → NotificationActionHandler.handle(response)
  → Extract itemID from notification identifier
  → Repository.markDone(itemID) — direct SwiftData access, no ViewModel needed
  → Cancel any remaining notifications for this item
  → Update badge count
```

### Notification Identifier Convention

```
Reminder:       "yata-reminder-{item.id}"
Snooze:         "yata-snooze-{item.id}"       // replaces reminder
Morning digest: "yata-digest-{yyyy-MM-dd}"
Overdue nudge:  "yata-overdue-{item.id}"
```

Prefix-based, so bulk cancellation by type is easy: `removeAllPendingNotificationRequests()` filtered by prefix.

---

## Settings Surface

New section in `SettingsView`:

```
Notifications
  ├── [Toggle] Morning Digest          (Phase 2, default: on)
  │     └── Time picker: 8:00 AM
  ├── [Toggle] Overdue Nudges           (Phase 2, default: on)
  ├── Smart Snooze                      (Phase 2)
  │     └── [Toggle] Use contextual intervals (default: on)
  ├── Quiet Hours                       (Phase 2)
  │     └── From: 10:00 PM  To: 7:00 AM
  └── [Button] Reset Notification Preferences
```

Phase 1 has no settings — it "just works" with sensible defaults.

---

## Implementation Order

| Step | Phase | Scope | Dependencies |
|------|-------|-------|-------------|
| 1 | 1 | `NotificationScheduler` service | None |
| 2 | 1 | `NotificationPermissionManager` | None |
| 3 | 1 | Permission flow in `ReminderPickerSheet` | Step 2 |
| 4 | 1 | `AppDelegate` + `UNUserNotificationCenterDelegate` | Step 1 |
| 5 | 1 | Wire scheduling into `HomeViewModel` state changes | Steps 1, 4 |
| 6 | 1 | Launch reconciliation (`syncAllReminders`) | Step 1 |
| 7 | 1 | Notification action handlers (Done/Snooze/Tomorrow) | Step 4 |
| 8 | 1 | Badge management | Step 7 |
| 9 | 1 | `RepeatingItem.reminderOffset` + materialization | Step 5 |
| 10 | 1b | Overdue nudge category | Steps 5, 7 |
| 11 | 2 | Morning digest | Steps 4, 6 |
| 12 | 2 | Smart snooze intervals | Step 7 |
| 13 | 2 | Fatigue detection + throttling | Step 7 |
| 14 | 2 | Priority-differentiated delivery | Step 5 |
| 15 | 2 | Overdue escalation reframing | Step 10 |
| 16 | 2 | Settings UI | Steps 11-15 |
| 17 | 3 | Task text parser | None |
| 18 | 3 | Notification rewriter (LLM integration) | Step 17 |
| 19 | 3 | Behavior tracker | Step 7 |
| 20 | 3 | Calendar context injection | Step 18 |

---

## Edge Cases

| Scenario | Handling |
|----------|---------|
| User sets reminder in past | Don't schedule notification. Show inline warning in picker: "This time has already passed" |
| Item marked done before reminder fires | Cancel pending notification in `markDone()` |
| Item deleted | Cancel in `deleteItem()` |
| Item rescheduled to tomorrow | Cancel current, schedule new with same time-of-day on new date |
| App killed and relaunched | `syncAllReminders()` reconciles on launch |
| User revokes notification permission in Settings | `syncAllReminders()` detects `.denied`, clears all pending. In-app indicators persist. |
| Snooze while in Do Not Disturb | Notification queues normally — DND is iOS's responsibility, not ours |
| Multiple snoozes on same item | Each snooze replaces the previous notification (same identifier) |
| Device timezone changes | `UNCalendarNotificationTrigger` uses local calendar — handles TZ automatically |
| 64 notification limit (iOS cap) | `syncAllReminders()` prioritizes: Now > Soon > Later, earliest first. Log warning if truncated. |
| Repeating item reminder for future occurrence | Only schedule for materialized items (items that exist in SwiftData). Don't pre-schedule for un-materialized future dates. |

---

## What We're NOT Building

- **Push notifications** — everything is local. No server, no APNs, no backend.
- **Location-based reminders** — adds complexity (permissions, battery) without clear ADHD benefit.
- **Social/sharing features** — no "accountability partner" notifications. Too much social pressure.
- **Streaks or gamification** — broken streaks cause shame spirals in ADHD users. No streak counters, no "you missed yesterday" messaging.
- **Notification sounds per item** — choice overload. One sound per priority level (Phase 2) is sufficient.
