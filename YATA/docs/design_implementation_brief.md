# YATA Design Implementation Brief

**Generated:** 2026-04-04
**Source:** design_review.md decisions

## Approved Changes (12 of 14)

| # | Change | Effort | Files Touched |
|---|--------|--------|---------------|
| 1 | Lane labels always visible ("Now"/"Soon"/"Later") | Low | PriorityContainerView |
| 2 | Move add button to bottom of lanes + Cmd+N | Low | PriorityContainerView, HomeView |
| 3 | Swipe hint (first session) + delete in edit sheet | Low | TodoPillView, PriorityContainerView |
| 4 | Rename labels: Now / Soon / Later | Trivial | Priority.swift, RepeatingAddEditSheet |
| 5 | Completion animation + progress bar | Medium | TodoPillView, DoneSectionView, HomeViewModel, Repository |
| 6 | Dot ring on week strip | Medium | WeekStripView, DotRingView (new), HomeViewModel, Repository |
| 7 | Bridge repeating tab (popover, next date, caption) | Medium | TodoPillView, RepeatingPillView, AddEditSheet, Repository |
| 10 | Swipe-right to reschedule tomorrow | Medium | TodoPillView, PriorityContainerView, HomeViewModel, Repository |
| 11 | Overdue badge on pills | Low | TodoPillView |
| 12 | Drag-drop feedback (ghost + glow) | Low | TodoPillView, PriorityContainerView, HomeViewModel |
| 13 | Typography hierarchy | Trivial | YATATheme, TodoPillView |
| 14 | iPad Kanban layout | Medium | HomeView |

**Skipped:** #8 (bulk operations), #9 (collapse settings)

## Implementation Phases

### Phase 1: Pure Model/Text (no UI risk)
- Change 4: Rename labels
- Change 13: Typography constants

### Phase 2: Data Layer
- Change 6 data: fetchTaskCountsByPriority
- Change 10 data: reschedule resetCount param + rescheduleToTomorrow
- Change 5 data: countDoneItems + progress properties
- Change 7 data: fetchRepeatingItem(by:)

### Phase 3: Simple View Changes
- Change 1: Lane labels
- Change 2: Move add button + drop delegate math
- Change 11: Overdue badge
- Change 12: Drag-drop feedback
- Change 3: Swipe hint

### Phase 4: Complex View Changes
- Change 10 view: Swipe-right gesture
- Change 5 view: Completion animation + progress bar
- Change 6 view: Dot ring

### Phase 5: Multi-File Features
- Change 7 view: Bridge repeating (popover + next date + caption)
- Change 14: iPad Kanban layout

## Critical Risk Areas
1. Drop delegate Y-offset math after moving add button + adding lane label
2. TodoPillView parameter count (7 changes touch this file)
3. Bidirectional swipe gesture vs drag-to-reorder conflict
4. Nested ScrollView on iPad layout

## New Files
- YATA/Views/DotRingView.swift
- YATA/Views/RepeatSourcePopover.swift
