import SwiftUI

struct RepeatingPillView: View {
    let item: RepeatingItem
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: Double = 0
    @State private var triggerDeleteHaptic = false

    private let deleteThreshold: Double = -150

    var body: some View {
        ZStack {
            HStack {
                Spacer()
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
                    .padding(.trailing, 20)
            }
            .frame(height: YATATheme.pillHeight)
            .background(.red, in: .capsule)
            .opacity(dragOffset < 0 ? min(1, Double(abs(dragOffset)) / abs(deleteThreshold)) : 0)

            pillContent
                .offset(x: dragOffset)
                .gesture(swipeToDeleteGesture)
        }
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(YATATheme.pillFont)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "alarm.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(item.scheduleSummary)
                .font(YATATheme.captionFont)
                .foregroundStyle(.secondary)

            Text(item.frequency.label)
                .font(YATATheme.captionFont)
                .foregroundStyle(.tertiary)

            Button("Edit", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: YATATheme.pillHeight)
        .contentShape(.capsule)
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
}
