import SwiftUI
import UniformTypeIdentifiers

struct TodoPillView: View {
    let item: TodoItem
    let isDragging: Bool
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

    var body: some View {
        ZStack {
            // Red delete background (left swipe)
            HStack {
                Spacer()
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
                    .padding(.trailing, 20)
            }
            .frame(height: YATATheme.pillHeight)
            .background(.red, in: .capsule)
            .opacity(dragOffset < 0 ? min(1, Double(abs(dragOffset)) / abs(deleteThreshold)) : 0)

            // Blue reschedule background (right swipe)
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.white)
                    .padding(.leading, 20)
                Spacer()
            }
            .frame(height: YATATheme.pillHeight)
            .background(.tint, in: .capsule)
            .opacity(dragOffset > 0 ? min(1, dragOffset / rescheduleThreshold) : 0)

            // Main pill content
            pillContent
                .offset(x: dragOffset)
                .gesture(swipeGesture)
        }
        .opacity(isDragging ? 0.3 : 1.0)
        .shadow(
            color: justDropped ? YATATheme.backgroundColor(for: lanePriority).opacity(0.8) : .clear,
            radius: justDropped ? 8 : 0
        )
        .scaleEffect(isCompleting ? 0.0 : 1.0)
        .opacity(isCompleting ? 0 : 1)
        .offset(x: isCompleting ? 100 : 0)
        .contentShape(.dragPreview, Capsule())
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
        .onAppear {
            if !hasSeenSwipeHint && lanePriority == .high {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !hasSeenSwipeHint else { return }
                    withAnimation(.spring(duration: 0.6)) {
                        dragOffset = -30
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.spring(duration: 0.6)) {
                        dragOffset = 0
                    }
                    hasSeenSwipeHint = true
                }
            }
        }
    }

    // MARK: - Pill Content

    private var pillContent: some View {
        HStack(spacing: 6) {
            // Overdue badge
            if item.rescheduleCount >= 2 {
                Text("\(item.rescheduleCount)")
                    .font(YATATheme.overdueBadgeFont)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(
                        item.rescheduleCount >= 5 ? Color.red : Color.orange,
                        in: .circle
                    )
            }

            if item.isRepeatingOccurrence {
                Image(systemName: "repeat")
                    .font(YATATheme.metadataIconFont)
                    .foregroundStyle(.tertiary)
            }

            Text(item.title)
                .font(YATATheme.pillFont)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let date = item.reminderDate {
                Image(systemName: "bell.fill")
                    .font(YATATheme.metadataIconFont)
                    .foregroundStyle(.tertiary)
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(YATATheme.captionFont)
                    .foregroundStyle(.secondary)
            }

            Button("Edit", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .font(YATATheme.metadataIconFont)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: YATATheme.pillHeight)
        .contentShape(.capsule)
        .onTapGesture { markDone() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Mark \(item.title) as done")
        .background(.regularMaterial, in: .capsule)
    }

    // MARK: - Bidirectional Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let horizontal = value.translation.width
                dragOffset = horizontal
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
                    withAnimation(.bouncy) {
                        dragOffset = 0
                    }
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
}
