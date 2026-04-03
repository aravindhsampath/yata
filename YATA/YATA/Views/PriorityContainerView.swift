import SwiftUI

struct PriorityContainerView: View {
    let priority: Priority
    @Bindable var viewModel: HomeViewModel

    private var items: [TodoItem] { viewModel.items(for: priority) }

    var body: some View {
        VStack(spacing: YATATheme.pillSpacing) {
            addButton

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // Show placeholder above this item if it's the drop target
                if isDropTarget(at: index) {
                    dropPlaceholder
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Hide the item being dragged (it's shown as the drag preview)
                TodoPillView(
                    item: item,
                    onMarkDone: { Task { await viewModel.markDone(item) } },
                    onEdit: { viewModel.editingItem = item },
                    onDelete: { Task { await viewModel.deleteItem(item) } },
                    onDragStart: { viewModel.startDrag(itemID: item.id) }
                )
                .opacity(viewModel.draggingItemID == item.id ? 0.3 : 1)
                .dropDestination(for: String.self) { ids, _ in
                    handleItemDrop(ids, atIndex: index)
                } isTargeted: { targeted in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if targeted {
                            viewModel.dropTarget = .init(priority: priority, index: index)
                        } else if isDropTarget(at: index) {
                            viewModel.dropTarget = nil
                        }
                    }
                }
            }

            // Placeholder at the end of the list
            if isDropTarget(at: items.count) {
                dropPlaceholder
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(YATATheme.containerPadding)
        .containerStyle(color: YATATheme.backgroundColor(for: priority))
        .dropDestination(for: String.self) { ids, _ in
            // Drop on empty area = append at end
            handleItemDrop(ids, atIndex: items.count)
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.2)) {
                if targeted && viewModel.dropTarget == nil {
                    viewModel.dropTarget = .init(priority: priority, index: items.count)
                }
            }
        }
    }

    // MARK: - Subviews

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

    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: YATATheme.pillHeight / 2)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(height: YATATheme.pillHeight)
    }

    // MARK: - Helpers

    private func isDropTarget(at index: Int) -> Bool {
        viewModel.dropTarget?.priority == priority && viewModel.dropTarget?.index == index
    }

    private func addTapped() {
        viewModel.addingToPriority = priority
    }

    private func handleItemDrop(_ ids: [String], atIndex index: Int) -> Bool {
        guard let idString = ids.first,
              let uuid = UUID(uuidString: idString) else { return false }
        Task { await viewModel.handleDrop(itemID: uuid, toPriority: priority, atIndex: index) }
        return true
    }
}
