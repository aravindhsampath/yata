import SwiftUI

struct DoneSectionView: View {
    @Bindable var viewModel: HomeViewModel

    @State private var triggerUndoneHaptic = false

    var body: some View {
        if !viewModel.doneItems.isEmpty {
            VStack(alignment: .leading, spacing: YATATheme.pillSpacing) {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(viewModel.doneItems) { item in
                    doneRow(item)
                }
            }
            .padding(YATATheme.containerPadding)
            .containerStyle(color: YATATheme.doneBackgroundColor)
            .sensoryFeedback(.success, trigger: triggerUndoneHaptic)
        }
    }

    private func doneRow(_ item: TodoItem) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(YATATheme.pillFont)
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let date = item.reminderDate {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(YATATheme.captionFont)
                    .foregroundStyle(.tertiary)
            }

            Button("Edit", systemImage: "pencil", action: { viewModel.editingItem = item })
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: YATATheme.pillHeight)
        .contentShape(.capsule)
        .onTapGesture { markUndone(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Mark \(item.title) as not done")
        .background(.regularMaterial, in: .capsule)
    }

    private func markUndone(_ item: TodoItem) {
        triggerUndoneHaptic.toggle()
        Task { await viewModel.markUndone(item) }
    }
}
