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
        .containerStyle(color: YATATheme.backgroundColor(for: priority))
        .dropDestination(for: String.self) { droppedIDs, _ in
            handleDrop(droppedIDs)
        }
    }

    private var addButton: some View {
        Button(action: addTapped) {
            HStack {
                Image(systemName: "plus")
                Text("Add")
            }
            .font(YATATheme.pillFont)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: YATATheme.pillHeight)
            .contentShape(.capsule)
        }
        .background(.regularMaterial, in: .capsule)
    }

    private func addTapped() {
        viewModel.addingToPriority = priority
    }

    private func handleDrop(_ droppedIDs: [String]) -> Bool {
        guard let idString = droppedIDs.first,
              let uuid = UUID(uuidString: idString) else { return false }

        let existsInSamePriority = viewModel.items(for: priority).contains { $0.id == uuid }

        if existsInSamePriority {
            return true
        } else {
            let allItems = Priority.allCases.flatMap { viewModel.items(for: $0) }
            guard let item = allItems.first(where: { $0.id == uuid }) else { return false }
            Task { await viewModel.moveItem(item, to: priority) }
            return true
        }
    }
}
