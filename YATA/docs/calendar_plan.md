# YATA Calendar Integration — Architecture Plan

**Status:** Planning  
**Last updated:** 2026-04-03

---

## Overview

Integrate a week-based calendar view into YATA's home screen, making todo items date-scoped with automatic rollover. This transforms YATA from a flat todo list into a time-aware task manager while preserving its minimal, ADHD-focused design.

---

## Product Decisions (Resolved)

### Week Strip
- Home screen shows today + 6 days forward (no past dates)
- Today is always position 0, selected by default
- Header format: "Fri Apr 3" above the strip
- Strip format: `M T W T F S S` weekday labels over `30 1 2 3 4 5 6` date numbers
- Current date visually highlighted as selected
- Tapping a date shows that date's todo items in the three-lane view below

### Urgency Lanes (not "priorities")
- **Green — Do Today**: tasks you're tackling now
- **Yellow — Aim for This Week**: important but not burning
- **Red — Interesting, But Wait**: only pick up when greens and yellows are clear
- These are urgency lanes designed to protect ADHD focus, not traditional priority levels
- The color choice is made per-item at creation time

### Rollover
- At midnight, all undone items where `scheduledDate < today` move to today
- `rescheduleCount` incremented on each rollover
- No collapsing, no grouping, no "X items from yesterday" — items pile up visibly
- The growing pile is intentional pressure to triage
- Rollover runs on app launch + midnight timer if foregrounded

### Rescheduling
- Available in the edit view for all items (manual and repeating occurrences)
- User picks a future date; item moves to that date
- Resets `rescheduleCount` to 0
- This is an honest act of time management, not avoidance

### Future Date Views
- Tapping a future date shows items scheduled for that day
- Adding an item from a future date's view schedules it for that date
- These are not "due dates" — they represent "when this lands on my plate"
- Repeating item occurrences also visible on their scheduled dates

### Done Items
- Global "recently done" list, not per-date
- Done items are never deleted from the database
- Configurable limit in Settings (how many to show)
- Provides visible accomplishment record for ADHD motivation

### Repeating Items in Home View
- Occurrences appear as regular TodoItems with `sourceRepeatingID` set
- From Home: can mark done or delete the occurrence only
- To change the schedule/rule: must go to Repeating tab
- No "skip this week", no early completion, no occurrence editing
- Repeating items get a `defaultUrgency` (lane color) set in the Repeating tab

---

## Data Model Changes

### TodoItem (modified)

```
Current fields (unchanged):
  id: UUID                      @Attribute(.unique)
  title: String
  priorityRawValue: Int         // rename semantically to urgencyRawValue in future
  isDone: Bool
  sortOrder: Int
  reminderDate: Date?
  createdAt: Date
  completedAt: Date?

New fields:
  scheduledDate: Date           // date-only — the day this item belongs to
  sourceRepeatingID: UUID?      // nil = manual item, set = spawned from repeating rule
  rescheduleCount: Int          // 0 for new, incremented on each rollover
```

**Migration for existing items:**
- Active items: `scheduledDate = today`
- Done items: `scheduledDate = completedAt` (date portion) or `createdAt` if nil

**Index change:**
- From: `[isDone, priorityRawValue, sortOrder]`
- To: `[isDone, scheduledDate, priorityRawValue, sortOrder]`

### RepeatingItem (modified)

```
Current fields (unchanged):
  id: UUID
  title: String
  frequencyRawValue: Int
  scheduledTime: Date
  scheduledDayOfWeek: Int?
  scheduledDayOfMonth: Int?
  scheduledMonth: Int?
  sortOrder: Int
  createdAt: Date

New field:
  defaultUrgencyRawValue: Int   // which lane (green/yellow/red) spawned items land in
```

### No New Models

Occurrences are just TodoItems with `sourceRepeatingID` set. No separate occurrence table. This keeps the query model simple — the home view fetches TodoItems by date, regardless of origin.

---

## Key Logic

### Rollover (on app launch + midnight)

```
Query:  scheduledDate < today AND isDone == false
Action: set scheduledDate = today, increment rescheduleCount
```

This is a data mutation, not a virtual query. Reasons:
1. Week strip only shows today + future — today's query must include rolled-over items
2. Sort order needs to be per-date; stale positions from original dates don't make sense
3. When API arrives, rollover will be server-side — local mutation mirrors that behavior

### Occurrence Materialization

**When:** App launch + navigating to a new date in the week strip

**For the visible range (today + 6 days):**
1. For each RepeatingItem, compute which dates in range it fires on
2. For each firing date, check if TodoItem exists with matching `sourceRepeatingID` and `scheduledDate`
3. If not, create TodoItem:
   - `title` = rule's title
   - `scheduledDate` = firing date
   - `priority` = rule's `defaultUrgency`
   - `sourceRepeatingID` = rule's id
   - `sortOrder` = append to end of that lane
   - `rescheduleCount` = 0

**Frequency → date math:**
- Daily: every day in range
- Workdays: Mon-Fri in range
- Weekly: dates matching `scheduledDayOfWeek`
- Monthly: dates matching `scheduledDayOfMonth`
- Yearly: dates matching `scheduledMonth` + `scheduledDayOfMonth`

### Reschedule (from edit view)

```
User picks new date (must be >= today)
Action: set scheduledDate = newDate, rescheduleCount = 0
```

Item disappears from current date's view, appears on new date.

---

## Repository Changes

### TodoRepository Protocol

```swift
// Changed signatures:
func fetchItems(for date: Date, priority: Priority) async throws -> [TodoItem]
func fetchDoneItems(limit: Int) async throws -> [TodoItem]  // global, configurable limit

// New methods:
func rolloverOverdueItems(to date: Date) async throws
func materializeRepeatingItems(for dateRange: ClosedRange<Date>) async throws
func reschedule(_ item: TodoItem, to date: Date) async throws
```

### RepeatingRepository Protocol

No changes needed — it manages rules, not occurrences.

---

## ViewModel Changes

### HomeViewModel

```swift
// New state:
var selectedDate: Date = .now  // date-only
var weekDates: [Date]          // computed: today + 6 days

// Changed behavior:
func loadAll() — now scoped to selectedDate
func selectDate(_ date: Date) — reloads items for new date
func addItem(...) — sets scheduledDate = selectedDate

// New behavior:
func performRollover() — called on init/app launch
func materializeRepeatingItems() — called on init + date change
```

### Done section
- No longer per-date
- `fetchDoneItems(limit:)` returns global recent completions
- Limit configurable via `@AppStorage("doneListSize")`

---

## View Changes

### HomeView

```
┌─────────────────────────────┐
│          TO DO              │
│       Fri Apr 3             │
│  T  W  T  F  S  S  M       │  ← weekday labels
│  3  4  5  6  7  8  9       │  ← date numbers (3 highlighted)
│                             │
│  ┌─ Green Lane ──────────┐  │
│  │ + Add                 │  │
│  │ [pill] [pill] [pill]  │  │
│  └───────────────────────┘  │
│                             │
│  ┌─ Yellow Lane ─────────┐  │
│  │ + Add                 │  │
│  │ [pill] [pill]         │  │
│  └───────────────────────┘  │
│                             │
│  ┌─ Red Lane ────────────┐  │
│  │ + Add                 │  │
│  │ [pill]                │  │
│  └───────────────────────┘  │
│                             │
│  ┌─ Recently Done ───────┐  │
│  │ [done] [done] [done]  │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

### AddEditSheet
- Add "Reschedule" date chip (same tappable pattern as repeating sheet)
- Shows current `scheduledDate`, tap to pick new date
- Only dates >= today selectable

### SettingsView
- Add "Recently Done" size picker (10, 25, 50, 100)

---

## Implementation Phases

### Phase 1: Data Model Migration
- Add `scheduledDate`, `sourceRepeatingID`, `rescheduleCount` to TodoItem
- Add `defaultUrgencyRawValue` to RepeatingItem
- Update SwiftData indexes
- Migrate existing data
- **No UI changes yet** — app works exactly as before, all items have scheduledDate = today

### Phase 2: Date-Scoped Queries
- Update repository protocol with date-scoped fetch methods
- Update LocalTodoRepository implementation
- Update HomeViewModel to hold `selectedDate` and reload on change
- Update done section to global with configurable limit
- **App still looks the same** but data layer is date-aware

### Phase 3: Week Strip UI
- Build week strip component (today + 6 days)
- Wire tap to `selectedDate` change
- Update "Add" to pass `selectedDate`
- Home view now shows date-scoped content

### Phase 4: Rollover
- Implement `rolloverOverdueItems(to:)` in repository
- Call on app launch in HomeViewModel.init
- Schedule midnight timer for foregrounded app
- Add `rescheduleCount` increment

### Phase 5: Occurrence Materialization
- Implement frequency → date math
- Implement `materializeRepeatingItems(for:)` in repository
- Call on app launch + date selection change
- Add `defaultUrgency` picker to RepeatingAddEditSheet

### Phase 6: Reschedule
- Add date chip to AddEditSheet
- Implement `reschedule(_:to:)` in repository
- Wire up ViewModel

### Phase 7: Settings
- Add "Recently Done" limit to SettingsView
- Wire to `@AppStorage` and done section query

---

## Local-Only vs. API Dual Mode

### Architecture Decision: Option A with Offline Queue

The app supports two modes, selectable in Settings:

1. **Local-only** (default): SwiftData is the source of truth. Fully functional, no account needed.
2. **API-connected**: Self-hosted API is the source of truth. Local SwiftData is a cache + offline store.

### How it works:

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│  ViewModel  │ ──→ │   Repository     │ ──→ │  SwiftData  │  (local mode)
└─────────────┘     │   (protocol)     │     └─────────────┘
                    └──────────────────┘

┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│  ViewModel  │ ──→ │  SyncRepository  │ ──→ │     API     │  (connected mode)
└─────────────┘     │  (writes to both)│ ──→ │  SwiftData  │
                    └──────────────────┘     └─────────────┘
```

- `SyncRepository` wraps both API and local, implementing the same `TodoRepository` protocol
- Online: reads from API, writes to both API + local cache
- Offline: reads/writes to local, queues operations for sync
- On reconnect: replays queue against API
- Conflicts: API wins (last-write-wins with server timestamp)

### What the API enables:
- Cross-device sync
- Web dashboard for bulk task management
- External integrations (Shortcuts, CLI, bots)
- Server-side rollover at actual midnight (not dependent on app being open)
- Server-side materialization of repeating items

### What stays local-only regardless:
- The app is always fully functional offline
- No account required for basic use
- Data ownership — user controls their API server

### Current repository protocol is the right seam:
The existing `TodoRepository` protocol already abstracts the storage layer. The ViewModel doesn't know or care whether it's talking to SwiftData or an API. When the API arrives, we write `SyncRepository` (or rename the stub `APITodoRepository`) and swap it in via a Settings toggle. Views and models don't change.

---

## Open Items / Future Considerations

- **Semantic rename**: `priority` → `urgency` across codebase (low priority, do when convenient)
- **Repeating item occurrence indicator**: subtle icon on pills spawned from rules, so user knows it's a repeating occurrence
- **Week strip swipe**: currently fixed to today + 6. Future: allow swiping to see further ahead?
- **Overdue badge**: use `rescheduleCount` to show how many days an item has been rolling over
- **Background rollover**: when API is available, server handles midnight rollover. For local-only, explore BackgroundTasks framework.
- **Notification integration**: `reminderDate` already exists on TodoItem — wire to UNUserNotificationCenter
