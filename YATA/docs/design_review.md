# YATA Design Review & Improvement Plan

**Date:** 2026-04-04
**Perspective:** UI/UX design critique with qualified implementation advice
**Scope:** All screens, interactions, and visual design decisions

---

## What Works Well

- Color-coded priority lanes provide instant visual scanning
- Capsule pill aesthetic is clean and modern
- Haptic feedback on swipe-delete and drag-drop gives the app physicality
- Week strip constrains planning to "this week" — avoids calendar overwhelm
- Dark mode glow and grain texture add subtle depth without performance cost

---

## Issues & Recommendations

### 1. No Empty States — The App Feels Broken When New

**Problem:** A fresh install shows three colored boxes with "Add" buttons and nothing else. No welcome, no explanation of what the three lanes mean, no nudge to create a first task. New users see colored rectangles and have to guess.

**Recommendation:** Each empty priority container shows a single ghost pill — a dashed-outline capsule with contextual placeholder text:

- High lane: *"What must get done today?"*
- Medium lane: *"What else is on your plate this week?"*
- Low lane: *"Anything you're parking for later?"*

Tapping the ghost pill opens the add sheet pre-set to that priority. The ghost disappears once the lane has at least one item. No modals, no tutorials, no "Welcome to YATA" — the empty state *is* the onboarding. The phrasing teaches the mental model (urgency, not time) while inviting action.

**Avoid:** Full-screen walkthrough. YATA is a simple app — if it needs a tutorial, the UI failed.

**Effort:** Low | **Impact:** High
Decision: We are going to add a subtle description for each region that always stays.. **"Now" / "Soon" / "Later"**
---

### 2. Move Add Buttons to Bottom of Lanes

**Problem:** The add button sits at the top of each lane, above the items. As tasks are added, they push further from the button. The natural flow is: scan items, decide to add, tap — the add affordance should be at the end.

**Recommendation:** Keep per-lane add buttons (they are pre-categorization, not decision paralysis), but move them to the bottom of each container. The flow becomes: scroll through items, hit the end, "Add" is right there. This matches how iOS Lists work.

On iPad, add `Cmd+N` keyboard shortcut for quick-add defaulting to High priority.

**Avoid:** A single FAB with priority picker inside the sheet. YATA's identity is the three lanes — a single add button removes the spatial metaphor. Putting something "in the red zone" is faster than filling out a form.

**Effort:** Low | **Impact:** Medium
Decision: Move the Add button to the bottom of each region. Add keyboard shortcut for ipad. 
---

### 3. Swipe-to-Delete Discoverability

**Problem:** Zero visual hint that pills are swipeable. The -150pt threshold is hidden. Users who don't try swiping will never discover it. Swipe is the only way to delete from the list view.

**Recommendation (two changes):**

1. **First-session hint:** Track via `@AppStorage("hasSeenSwipeHint")`. After the user adds their first item, briefly animate that pill 30pt to the left and back with a 0.6s spring — like the pill is "breathing" to show it can move. One subtle hint, once, never again. This is the pattern iOS Mail and Reminders use.

2. **Redundant delete path:** Add a "Delete" button inside the edit sheet (red, destructive style). This gives a second path to deletion that doesn't depend on gesture knowledge. Swipe remains the fast path for experienced users.

**Avoid:** Tooltip or popover saying "swipe to delete." That's documentation, not design.

**Effort:** Low | **Impact:** Medium
Decision: Agreed on both recommendations.
---

### 4. Rename Priority Labels to Avoid Temporal Collision

**Problem:** "Do Today" / "This Week" / "Wait" sound like time horizons, not urgency. "This Week" next to a week calendar strip creates confusion — does it mean scheduled this week, or medium priority? The calendar handles *when*. The lanes should handle *importance*.

**Recommendation:** Rename to **"Now" / "Soon" / "Later"**

These are:
- Unambiguous (no collision with the week strip's time semantics)
- Short (fit in headers, pills, pickers)
- Action-oriented (they tell you *when to pay attention*)
- Naturally ordered (Now > Soon > Later)

Alternatives considered:
- "Must Do / Should Do / Can Wait" — solid but wordier
- "High / Medium / Low" — accurate but sterile, doesn't help the user *feel* the priority

**Effort:** Trivial (string changes) | **Impact:** High

Decision: Agreed. **"Now" / "Soon" / "Later"**
---

### 5. Completion Celebration & Progress Feedback

**Problem:** Checking off a task — the core dopamine hit of any todo app — gets a haptic buzz and the item vanishes into a collapsed list. No animation of the pill leaving, no progress indicator. The reward loop is flat.

**Recommendation (two changes):**

1. **Completion animation:** When marked done, the pill slides rightward + fades out with a brief scale pulse (1.0 -> 1.05 -> 0.0, ~0.3s). The existing haptic success feedback stays. This gives a sense of "I moved this forward."

2. **Progress indicator:** Replace the static "Done" disclosure header with a contextual line: **"3 of 7 done today"** with a thin progress bar in the tint color. The bar fills as tasks are completed. At 100%, swap to **"All done for today"**.

**Avoid:** Confetti, streaks, or gamification. YATA's aesthetic is calm and minimal — dopamine farming would clash with the design language. The reward should feel like quiet satisfaction, not a slot machine.

**Effort:** Medium | **Impact:** High
Decision: Agreed on both recommendations.
---

### 6. Task Density Indicators on Week Strip

**Problem:** Each day shows a number and a letter. No indication of whether Monday has 12 tasks and Thursday has zero. The strip is a date picker, not a planning tool.

**Recommendation:** Below each day number, show a row of tiny dots — one per undone task, capped at 3 dots with a "+" for overflow. Color the dots using lane colors (red/yellow/green) so you can see *what kind* of tasks are waiting.

Example: Monday shows `[red][red][yellow]` — heavy day. Thursday shows nothing — it's clear.

**Data approach:** Batch-fetch all 7 days' undone counts in a single predicate (`scheduledDate >= weekStart && scheduledDate < weekEnd`), bucket in-memory by day and priority. Refresh on data changes. Lightweight since the data is already local.

**Avoid:** Numeric badges ("12"). They create anxiety. Dots are visual texture, not numbers to stress about.

**Effort:** Medium | **Impact:** High
Decision: How about using the circular border of the date to make it feel like a subtle ring composed like a pie chart made of fixed number of dots. If there are 2 green tasks and 1 yellow tasks on that day, then there would be two green dots and 1 yellow dot and the remainder are default grey dots in that circle. If there are no planned activities for a day, it would be all grey dots composing that circle.
---

### 7. Bridge Repeating Tab to Home Screen

**Problem:** Repeating rules live on a separate tab with no visual connection to home. No way to navigate from a spawned occurrence back to its rule. Two-tab split creates a mental model gap.

**Recommendation (three links):**

1. **Occurrence -> Rule:** Tapping a spawned occurrence's repeat icon shows a small popover: "From: Daily task — Edit rule". Links the occurrence to its source.

2. **Rule -> Next occurrence:** On the Repeating tab, show a subtitle under each rule: "Next: Today" or "Next: Wednesday" — see when rules fire without switching tabs.

3. **Edit sheet context:** In the edit sheet for a spawned occurrence, show the rule name in a read-only caption: "Part of: Morning standup (daily)". Answers "why is this here?"

**Avoid:** Merging repeating rules into the home screen. They're templates, not tasks — mixing them confuses the data model and the user's mental model.

**Effort:** Medium | **Impact:** Medium

Decision: Agreed on all three recommendations.
---

### 8. Bulk Operations (V2)

**Problem:** No multi-select, no "clear all done," no "reschedule all to tomorrow." Power users will hit this wall.

**Recommendation:** Implement one bulk action first: **"Reschedule all to tomorrow."** This is the #1 end-of-day action. Surface it as a long-press on the date in the week strip, or as a toolbar menu option.

Second bulk action: **"Clear all done"** — a button in the done section header.

**Avoid:** A generic long-press multi-select system. It's complex to build, hard to make accessible, and YATA's item counts per lane are small enough that individual actions suffice for V1. Each bulk operation should be a specific, common workflow.

**Effort:** Medium | **Impact:** Medium (grows with user maturity)

Decision: skip this. Yata needs to be simple and minimal. These are features I could live without because tasks automagically gets carried over if not done that day. 

---

### 9. Collapse Settings into Home Screen

**Problem:** Two settings (appearance + done list size) don't justify a full tab. The third tab slot feels hollow.

**Recommendation:** Move settings to a gear icon in the home screen's navigation bar, opening a `.sheet` with `.presentationDetents([.medium])`. Go to two tabs: Home and Repeating.

Two-tab layouts are valid for focused apps. The tab bar becomes simpler, thumb zone less crowded, every tab earns its position.

If settings grow later (notifications, sync, account), promote back to a tab. But not yet.

**Effort:** Low | **Impact:** Low (polish)

Decision: Nope. Current state stays. There are more settings coming as app evolves. It will be justified soon.
---

### 10. Swipe-Right to Reschedule to Tomorrow

**Problem:** Rescheduling takes 4 steps: tap edit, find reschedule row, pick date, tap Move. The most common reschedule is "push to tomorrow."

**Recommendation:** Swipe *right* on a pill to reschedule to tomorrow. Creates a natural gesture vocabulary:

- **Swipe left** = remove (delete)
- **Swipe right** = defer (reschedule to tomorrow)

At ~80pt threshold, show a blue/tint-colored background with a calendar-arrow icon. The pill snaps back and the item silently moves to tomorrow. Brief inline toast at the bottom confirms: "Moved to tomorrow."

**Edge case:** If it's the last visible day in the week strip, swiping right should shift the week strip forward so the destination day is visible. Otherwise the item vanishes with no way to verify where it went.

For other reschedule targets (next week, specific date), the edit sheet flow remains. But "push to tomorrow" covers 80%+ of cases.

**Effort:** Medium | **Impact:** High

Decision. Love the right swipe to move to tomorrow. I can live with the edge case of swiping right on a task on the last visible day. Let it go to the next day without a way for the user to confirm its move. I am okay with that.
---

### 11. Overdue / Rolled-Over Visual Indicator

**Problem:** Items rolled over show an incremented `rescheduleCount` in the data model, but nothing in the UI changes. A task rolled over 5 times looks identical to one created fresh today. The procrastination signal is invisible.

**Recommendation:** A small, warm-colored badge on the pill's left edge:

| Rollover Count | Visual |
|----------------|--------|
| 0-1 | No indicator (life happens) |
| 2-4 | Flame-orange dot with count (e.g., `3`) |
| 5+ | Red dot with count |

The escalation is deliberate: gentle nudge at 2, stronger signal at 5. This creates *gentle accountability* — the user notices patterns in their own behavior. The implicit message at 5+: "This needs a decision — do it, delegate it, or drop it."

**Avoid:** Changing the pill's background color or adding warning triangles. The lanes already use color for priority — overdue indicators should be a *separate visual channel* (badge, not background) to avoid confusion.

**Effort:** Low | **Impact:** High

Decision: Good idea. Agreed with the color badge gentle nudge recommendation. It has to be subtle. 

---

### 12. Drag-and-Drop Feedback

**Problem:** No preview of which item is being dragged, no confirmation after the drop. The pill just appears in the new lane.

**Recommendation (two changes):**

1. **During drag:** The source pill dims to 30% opacity (a "ghost" showing where it came from).

2. **After drop:** The dropped pill gets a brief highlight animation — a 0.3s glow pulse in the destination lane's color, then fade to normal. Says "I landed here" without a toast.

**Avoid:** Banners or toasts for drag-drop. The spatial change (pill is now in a different colored zone) is confirmation enough when paired with the highlight.

**Effort:** Low | **Impact:** Low (polish)

Decision: Agreed with the recommendation as-is.

---

### 13. Typography Hierarchy Within Pills

**Problem:** Everything uses `.body.weight(.medium)`. Title, reminder badge, repeat icon, and edit button all compete at the same visual weight.

**Recommendation:** Three tiers:

| Element | Current | Proposed |
|---------|---------|----------|
| Task title | `.body.weight(.medium)` | Unchanged |
| Reminder time | `.caption` | `.caption2.weight(.regular)` + `.secondary` foreground |
| Repeat icon | Same weight as title | `.caption2` size + `.tertiary` foreground |
| Overdue badge | N/A | `.caption2.weight(.bold).monospacedDigit()` |

Principle: **if it's not the task name, it should be quieter than the task name.** Muting metadata lets the title dominate, which is correct — users scan a list of things to do, not a list of metadata.

**Effort:** Trivial | **Impact:** Medium

Decision: Agreed with the recommendation as-is.

---

### 14. iPad / Landscape Kanban Layout

**Problem:** The three-lane vertical stack wastes space on iPad. Lanes could sit side-by-side — a natural Kanban board.

**Recommendation:** Use horizontal size class to switch layouts:

- **Compact width** (iPhone portrait): Current vertical stack
- **Regular width** (iPad, iPhone landscape): Three lanes side-by-side in an `HStack`, each independently scrollable. Week strip spans the full top.

The data model and view models don't change. Only `HomeView` needs a conditional layout wrapper. Each `PriorityContainerView` already works as a standalone column.

**Key payoff:** On iPad, drag-and-drop between side-by-side lanes feels natural — it's a true Kanban drag. This is where YATA's drag-drop investment pays off most. The iPhone vertical layout makes cross-lane drag awkward (long vertical distance); the iPad horizontal layout makes it feel native.

**Effort:** Medium | **Impact:** Medium (audience-dependent)

Decision: Agreed with the recommendation as-is.
---

## Recommended Implementation Order

Sequenced for cumulative impact — each step builds on the previous:

| Phase | Issue | Description | Effort |
|-------|-------|-------------|--------|
| 1 | #4 | Rename labels to Now / Soon / Later | Trivial |
| 2 | #11 | Overdue rollover badge on pills | Low |
| 3 | #1 | Ghost pill empty states | Low |
| 4 | #5 | Completion animation + progress bar | Medium |
| 5 | #13 | Typography hierarchy in pills | Trivial |
| 6 | #2 | Move add buttons to bottom of lanes | Low |
| 7 | #10 | Swipe-right to reschedule to tomorrow | Medium |
| 8 | #6 | Task density dots on week strip | Medium |
| 9 | #3 | Swipe hint + delete in edit sheet | Low |
| 10 | #12 | Drag-drop ghost + highlight feedback | Low |
| 11 | #9 | Collapse settings into home sheet | Low |
| 12 | #7 | Bridge repeating tab to home screen | Medium |
| 13 | #14 | iPad side-by-side Kanban layout | Medium |
| 14 | #8 | Bulk reschedule-all-to-tomorrow | Medium |
