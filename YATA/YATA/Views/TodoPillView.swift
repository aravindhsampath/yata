import SwiftUI
import UniformTypeIdentifiers

struct TodoPillView: View {
    let item: TodoItem
    let onMarkDone: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDragStart: () -> Void

    @State private var dragOffset: Double = 0
    @State private var triggerDeleteHaptic = false
    @State private var triggerDoneHaptic = false
    @State private var triggerDragHaptic = false

    private let deleteThreshold: Double = -150

    var body: some View {
        ZStack {
            // Red delete background
            HStack {
                Spacer()
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
                    .padding(.trailing, 20)
            }
            .frame(height: YATATheme.pillHeight)
            .background(.red, in: .capsule)
            .opacity(dragOffset < 0 ? min(1, Double(abs(dragOffset)) / abs(deleteThreshold)) : 0)

            // Main pill content
            pillContent
                .offset(x: dragOffset)
                .gesture(swipeToDeleteGesture)
        }
        .onDrag {
            triggerDragHaptic.toggle()
            onDragStart()
            return NSItemProvider(object: item.id.uuidString as NSString)
        } preview: {
            Text(item.title)
                .font(YATATheme.pillFont)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: .capsule)
                .shadow(radius: 8)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: triggerDragHaptic)
        .sensoryFeedback(.success, trigger: triggerDoneHaptic)
        .sensoryFeedback(.warning, trigger: triggerDeleteHaptic)
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(YATATheme.pillFont)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let date = item.reminderDate {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(YATATheme.captionFont)
                    .foregroundStyle(.secondary)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: YATATheme.pillHeight)
        .contentShape(.capsule)
        .onTapGesture { markDone() }
        .background(.regularMaterial, in: .capsule)
    }

    private var swipeToDeleteGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let horizontal = value.translation.width
                if horizontal < 0 {
                    dragOffset = horizontal
                }
            }
            .onEnded { _ in
                if dragOffset < deleteThreshold {
                    triggerDeleteHaptic.toggle()
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -400
                    } completion: {
                        onDelete()
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
        onMarkDone()
    }
}
