import SwiftUI

struct PriorityContainerView: View {
    let priority: Priority
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        VStack(spacing: YATATheme.pillSpacing) {
            addButton
            ForEach(viewModel.items(for: priority)) { item in
                TodoPillView(
                    item: item,
                    onMarkDone: { Task { await viewModel.markDone(item) } },
                    onEdit: { viewModel.editingItem = item },
                    onDelete: { Task { await viewModel.deleteItem(item) } }
                )
            }
        }
        .padding(YATATheme.containerPadding)
        .background(
            YATATheme.backgroundColor(for: priority),
            in: .rect(cornerRadius: YATATheme.containerCornerRadius)
        )
        .dropDestination(for: String.self) { droppedIDs, _ in
            handleDrop(droppedIDs)
        }
    }

    private var addButton: some View {
        Button("Add", systemImage: "plus", action: addTapped)
            .font(YATATheme.pillFont)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: YATATheme.pillHeight)
            .background(.regularMaterial, in: .capsule)
    }

    private func addTapped() {
        viewModel.addingToPriority = priority
    }

    private func handleDrop(_ droppedIDs: [String]) -> Bool {
        guard let idString = droppedIDs.first,
              let uuid = UUID(uuidString: idString) else { return false }

        // Check if item is already in this priority (reorder) or from another (move)
        let existsInSamePriority = viewModel.items(for: priority).contains { $0.id == uuid }

        if existsInSamePriority {
            return true // Reorder handled by drag gestures
        } else {
            // Find the item across all priorities
            let allItems = Priority.allCases.flatMap { viewModel.items(for: $0) }
            guard let item = allItems.first(where: { $0.id == uuid }) else { return false }
            Task { await viewModel.moveItem(item, to: priority) }
            return true
        }
    }
}
