import SwiftUI
import UniformTypeIdentifiers

/// Single todo row in the redesigned home view.
///
/// Visual changes from the previous capsule pill:
/// - 52pt row, 14pt corner radius (was 40pt capsule).
/// - Transparent background — the row sits inside a surface section card,
///   so it earns separation from typography and the section's hairline
///   border, not from per-row chrome. While dragging, the row tints to
///   `yataSurfaceHi` so the user sees what's moving.
/// - Check circle on the LEFT (was overdue badge on the left). Filled in
///   `yataDoneSage` once complete; outline in `yataTextMute` otherwise.
/// - Carry-over (`rescheduleCount > 0`) is now an outlined amber pill in
///   mono caps, never a filled circle. Information, not shame.
/// - Title in Inter Variable 16/regular. Done state strikes through and
///   drops the title to `yataTextMute`.
/// - Swipe reveals use the new `yataAccent` (Tomorrow) and `yataDanger`
///   (Delete) instead of system tint / red.
///
/// All behaviors are preserved: drag-and-drop reorder, swipe gestures,
/// haptic feedback, just-dropped highlight, the first-time swipe hint,
/// and every accessibility action. Only the chrome moved.
struct TodoPillView: View {
    let item: TodoItem
    let justDropped: Bool
    let lanePriority: Priority
    let onMarkDone: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDragStart: () -> Void
    let onRescheduleTomorrow: () -> Void

    @AppStorage("hasSeenSwipeHint") private var hasSeenSwipeHint = false
    @State private var dragOffset: Double = 0
    @State private var triggerDeleteHaptic = false
    @State private var triggerDoneHaptic = false
    @State private var triggerDragHaptic = false
    @State private var triggerRescheduleHaptic = false
    @State private var isCompleting = false

    private let deleteThreshold: Double = -150
    private let rescheduleThreshold: Double = 80
    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: YATATheme.Radius.row, style: .continuous)
    }

    var body: some View {
        ZStack {
            // Left-revealed Delete background (row swiped LEFT = negative offset).
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Delete")
                        .font(YATAFont.text(13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.trailing, 18)
            }
            .frame(height: YATATheme.RowHeight.todo)
            .background(Color.yataDanger, in: rowShape)
            .opacity(dragOffset < 0 ? min(1, Double(abs(dragOffset)) / abs(deleteThreshold)) : 0)

            // Right-revealed Tomorrow background (row swiped RIGHT = positive offset).
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Tomorrow")
                        .font(YATAFont.text(13, weight: .semibold))
                }
                .foregroundStyle(Color.yataBG)
                .padding(.leading, 18)
                Spacer()
            }
            .frame(height: YATATheme.RowHeight.todo)
            .background(Color.yataAccent, in: rowShape)
            .opacity(dragOffset > 0 ? min(1, dragOffset / rescheduleThreshold) : 0)

            rowContent
                .offset(x: dragOffset)
                .gesture(swipeGesture)
        }
        .shadow(
            color: justDropped ? Color.yataAccent.opacity(0.5) : .clear,
            radius: justDropped ? 8 : 0
        )
        .scaleEffect(isCompleting ? 0.0 : 1.0)
        .opacity(isCompleting ? 0 : 1)
        .offset(x: isCompleting ? 100 : 0)
        .contentShape(.dragPreview, rowShape)
        .onDrag {
            triggerDragHaptic.toggle()
            onDragStart()
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: triggerDragHaptic)
        .sensoryFeedback(.success, trigger: triggerDoneHaptic)
        .sensoryFeedback(.warning, trigger: triggerDeleteHaptic)
        .sensoryFeedback(.impact(weight: .light), trigger: triggerRescheduleHaptic)
        .accessibilityAction(named: "Delete") { onDelete() }
        .accessibilityAction(named: "Reschedule to tomorrow") { onRescheduleTomorrow() }
        .animation(.easeOut(duration: 0.3), value: isCompleting)
        .animation(.easeOut(duration: 0.3), value: justDropped)
        .onAppear { runFirstTimeSwipeHintIfNeeded() }
    }

    // MARK: - Row content

    private var rowContent: some View {
        HStack(spacing: 12) {
            checkCircle

            // Title — single line, ellipsizes. Done strikes through and
            // drops to the muted token; lane-undone keeps full text.
            Text(item.title)
                .font(YATAFont.text(16))
                .foregroundStyle(item.isDone ? Color.yataTextMute : Color.yataText)
                .strikethrough(item.isDone, color: Color.yataTextMute)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Carry-over pill — outlined amber, mono caps. Hidden once done.
            if item.rescheduleCount > 0, !item.isDone {
                carryOverPill
            }

            if item.isRepeatingOccurrence {
                Image(systemName: "repeat")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.yataTextMute)
            }

            if let date = item.reminderDate {
                HStack(spacing: 4) {
                    Image(systemName: "bell")
                        .font(.system(size: 11, weight: .medium))
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(YATAFont.mono(10))
                }
                .foregroundStyle(Color.yataTextMute)
            }

            // Quiet edit chevron — long-press would be more on-design but
            // we're preserving an explicit button so accessibility still
            // has a clear hit target.
            Button(action: onEdit) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.yataTextMute)
            }
            .accessibilityLabel("Edit \(item.title)")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: YATATheme.RowHeight.todo)
        .background(
            // Tint to surfaceHi only while actively swiping; otherwise
            // transparent so the section card shows through.
            (dragOffset != 0 ? Color.yataSurfaceHi : .clear),
            in: rowShape
        )
        .contentShape(rowShape)
        .onTapGesture { markDone() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Mark \(item.title) as done")
    }

    // MARK: - Pieces

    private var checkCircle: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.yataTextMute, lineWidth: 1.5)
                .opacity(item.isDone ? 0 : 1)
            Circle()
                .fill(Color.yataDoneSage)
                .opacity(item.isDone ? 1 : 0)
            if item.isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.yataBG)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.18), value: item.isDone)
    }

    private var carryOverPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .semibold))
            Text("\(item.rescheduleCount)")
                .font(YATAFont.mono(10))
        }
        .foregroundStyle(Color.yataRolled)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .overlay(
            Capsule()
                .stroke(Color.yataRolled, lineWidth: 1)
        )
        .accessibilityLabel("Carried over \(item.rescheduleCount) days")
    }

    // MARK: - Bidirectional Swipe Gesture (unchanged behavior, restyled visuals)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { _ in
                if dragOffset < deleteThreshold {
                    triggerDeleteHaptic.toggle()
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -400
                    } completion: {
                        onDelete()
                    }
                } else if dragOffset > rescheduleThreshold {
                    triggerRescheduleHaptic.toggle()
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 400
                    } completion: {
                        onRescheduleTomorrow()
                    }
                } else {
                    withAnimation(.bouncy) { dragOffset = 0 }
                }
            }
    }

    private func markDone() {
        triggerDoneHaptic.toggle()
        isCompleting = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            onMarkDone()
        }
    }

    /// One-time hint: nudges the highest-priority lane's first row left a
    /// few points to teach the swipe-to-delete affordance. Behavior is
    /// preserved as-is from the previous capsule design — only the
    /// pixel offset survives changing geometry untouched.
    private func runFirstTimeSwipeHintIfNeeded() {
        guard !hasSeenSwipeHint, lanePriority == .high else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !hasSeenSwipeHint else { return }
            withAnimation(.spring(duration: 0.6)) { dragOffset = -30 }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.spring(duration: 0.6)) { dragOffset = 0 }
            hasSeenSwipeHint = true
        }
    }
}
