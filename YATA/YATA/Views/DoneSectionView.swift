import SwiftUI

struct DoneSectionView: View {
    let viewModel: HomeViewModel

    @State private var isExpanded = false

    var body: some View {
        if !viewModel.doneItems.isEmpty {
            VStack(alignment: .leading, spacing: YATATheme.pillSpacing) {
                Button(action: toggleExpanded) {
                    HStack {
                        Text("Done")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 4)

                if isExpanded {
                    ForEach(viewModel.doneItems) { item in
                        doneRow(item)
                    }
                }
            }
            .padding(YATATheme.containerPadding)
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
    }

    private func doneRow(_ item: TodoItem) -> some View {
        HStack {
            Text(item.title)
                .font(YATATheme.pillFont)
                .strikethrough()
                .foregroundStyle(.secondary)

            Spacer()

            if let completedAt = item.completedAt {
                Text(completedAt, format: .dateTime.month(.abbreviated).day())
                    .font(YATATheme.captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: YATATheme.pillHeight)
        .background(.quaternary, in: .capsule)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
