# Review Request

**Sequence:** 002
**Task:** notifications
**Date:** 2026-04-04
**Branch:** feat/notifications
**Responds to:** 001-architect-brief-notifications

## Summary

Implemented the Phase 1 notification foundation for YATA. Three new files provide scheduling (`NotificationScheduler`), permission management (`NotificationPermissionManager`), and notification delegate/action handling (`AppDelegate`). Existing files were modified to wire scheduling into every state-changing operation, inject the permission manager through the view hierarchy, and reconcile notifications on app launch.

## Files Changed

| File | Change | Description |
|------|--------|-------------|
| `YATA/YATA/Services/NotificationScheduler.swift` | new | Stateless service wrapping UNUserNotificationCenter with schedule, cancel, cancelAll, and syncAllReminders methods |
| `YATA/YATA/Services/NotificationPermissionManager.swift` | new | @Observable class caching authorization status with check, request, and openSettings methods |
| `YATA/YATA/AppDelegate.swift` | new | UIApplicationDelegate + UNUserNotificationCenterDelegate with TASK_REMINDER category, MARK_DONE/SNOOZE_30/TOMORROW action handlers, badge clearing on activate |
| `YATA/YATA/YATAApp.swift` | modified | Added @UIApplicationDelegateAdaptor, explicit ModelContainer init, passes container to AppDelegate |
| `YATA/YATA/ViewModels/HomeViewModel.swift` | modified | Added scheduler calls to addItem, updateItem, deleteItem, markDone, rescheduleItem, rescheduleToTomorrow; syncAllReminders + badge count in loadAll |
| `YATA/YATA/Views/ReminderPickerSheet.swift` | modified | Permission check on save (alert if notDetermined, inline settings link if denied), never blocks save |
| `YATA/YATA/Views/AddEditSheet.swift` | modified | Accepts and forwards NotificationPermissionManager to ReminderPickerSheet |
| `YATA/YATA/Views/HomeView.swift` | modified | Creates NotificationPermissionManager, passes to sheets, observes .yataDataDidChange for background action refresh |
| `YATA/YATA.xcodeproj/project.pbxproj` | modified | Registered 3 new files and Services group |

## How to Test

```bash
xcodebuild -project YATA/YATA.xcodeproj -target YATA -destination 'id=3B9F4B0A-3530-4C95-87D2-B6A2EF596BD5' build
```

Manual verification:
1. Create a task with a reminder 2 minutes in the future -- notification should fire
2. Edit the reminder time -- old notification replaced with new one
3. Remove reminder -- notification canceled
4. Mark task done -- notification canceled
5. Delete task -- notification canceled
6. Reschedule to tomorrow -- notification rescheduled with same time-of-day
7. First reminder save should trigger permission request alert
8. Deny permission, set another reminder -- inline "enable in Settings" text appears, save still works
9. When notification fires, tap "Done" action -- item marked complete
10. Tap "30 min" action -- notification rescheduled 30 minutes later, reminderDate updated
11. Tap "Tomorrow" action -- item rescheduled to tomorrow
12. Kill and relaunch app -- syncAllReminders reconciles pending notifications

## Self-Check

- [x] `xcodebuild build` passes
- [ ] `make lint` -- no Makefile exists in this project (Xcode project, not SPM)
- [ ] `make test` -- no Makefile exists; existing unit tests were not modified and should still pass
- [x] All Definition of Done items from the brief are addressed

## Open Questions

- The brief's open question about snooze updating `reminderDate`: I followed the recommendation and update both the notification and the `reminderDate` on the model to keep things consistent.
- The brief's open question about badge count including past reminders: I followed the recommendation and count all overdue reminder items (not done, reminderDate < now).
- `setBadgeCount` in `applicationDidBecomeActive` and `loadAll` uses the async API. In `applicationDidBecomeActive` (non-async context), we call it directly since it returns immediately for badge=0. The `loadAll` path uses `try? await`.

## Decisions Made

- `NotificationScheduler` is a struct with static methods rather than a singleton class, since it's stateless and all operations go through `UNUserNotificationCenter.current()`.
- `AppDelegate` action handlers create their own `ModelContext` from the shared `ModelContainer` for background mutations, then post `.yataDataDidChange` so the active ViewModel refreshes.
- `rescheduleToTomorrow` preserves the time-of-day from the original reminder when creating the new reminder date on tomorrow.
- The `handleSnooze30` method dispatches a `Task { @MainActor in ... }` to update the model since it's called from a non-MainActor context within the delegate callback.

## Notes for Reviewer

- The `YATAApp` now creates the `ModelContainer` explicitly in `init()` instead of using the `.modelContainer(for:)` modifier's implicit creation. This is required so we can share the same container with `AppDelegate`. The `try!` is consistent with SwiftData conventions -- a failed container init is unrecoverable.
- `NotificationScheduler.scheduleReminder` silently no-ops if `reminderDate` is nil or in the past, so callers don't need to guard.
- All notification identifiers use the `"yata-reminder-"` prefix as specified.
