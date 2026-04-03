import SwiftUI
import UniformTypeIdentifiers

struct PriorityContainerView: View {
    let priority: Priority
    @Bindable var viewModel: HomeViewModel

    private var items: [TodoItem] { viewModel.items(for: priority) }

    var body: some View {
        VStack(spacing: YATATheme.pillSpacing) {
            addButton

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // Thin insertion indicator above this item
                if viewModel.dropTarget?.priority == priority
                    && viewModel.dropTarget?.index == index {
                    insertionIndicator
                }

                TodoPillView(
                    item: item,
                    onMarkDone: { Task { await viewModel.markDone(item) } },
                    onEdit: { viewModel.editingItem = item },
                    onDelete: { Task { await viewModel.deleteItem(item) } },
                    onDragStart: { viewModel.startDrag(itemID: item.id) }
                )
            }

            // Insertion indicator at the end
            if viewModel.dropTarget?.priority == priority
                && viewModel.dropTarget?.index == items.count {
                insertionIndicator
            }
        }
        .padding(YATATheme.containerPadding)
        .containerStyle(color: YATATheme.backgroundColor(for: priority))
        .overlay {
            // Invisible geometry reader to capture item frames
            GeometryReader { geo in
                Color.clear
                    .preference(key: ContainerFrameKey.self, value: geo.frame(in: .global))
            }
        }
        .onDrop(of: [UTType.text], delegate: PriorityDropDelegate(
            priority: priority,
            viewModel: viewModel
        ))
        .animation(.easeInOut(duration: 0.2), value: viewModel.dropTarget)
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

    private var insertionIndicator: some View {
        Capsule()
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(height: YATATheme.pillHeight)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func addTapped() {
        viewModel.addingToPriority = priority
    }
}

// MARK: - Preference key for container frame

private struct ContainerFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Drop delegate

private struct PriorityDropDelegate: DropDelegate {
    let priority: Priority
    let viewModel: HomeViewModel

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(from: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertionIndex(from: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Only clear if we're the current target
        if viewModel.dropTarget?.priority == priority {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTarget = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            viewModel.endDrag()
            return false
        }

        let targetIndex = viewModel.dropTarget?.index ?? viewModel.items(for: priority).count
        // Clear visual state immediately so pill doesn't stay faded
        viewModel.endDrag()

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String,
                  let uuid = UUID(uuidString: idString) else { return }
            Task { @MainActor in
                await viewModel.handleDrop(itemID: uuid, toPriority: priority, atIndex: targetIndex)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    // Calculate insertion index based on Y position within the container
    private func updateInsertionIndex(from info: DropInfo) {
        let items = viewModel.items(for: priority)
        let itemCount = items.count

        // Each pill takes pillHeight + pillSpacing, offset by add button + container padding
        let addButtonHeight = YATATheme.pillHeight + YATATheme.pillSpacing
        let containerPadding = YATATheme.containerPadding
        let itemSlotHeight = YATATheme.pillHeight + YATATheme.pillSpacing

        // Y position relative to the first item's top edge
        let relativeY = info.location.y - containerPadding - addButtonHeight

        // Calculate which slot the cursor is over
        let rawIndex: Int
        if relativeY < 0 {
            rawIndex = 0
        } else {
            // Use midpoint of each slot as the threshold
            rawIndex = min(Int((relativeY + itemSlotHeight / 2) / itemSlotHeight), itemCount)
        }

        // Skip the dragged item's own position to avoid visual noise
        let newIndex = rawIndex
        let currentTarget = viewModel.dropTarget

        // Only update if actually changed (debounce)
        if currentTarget?.priority != priority || currentTarget?.index != newIndex {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTarget = .init(priority: priority, index: newIndex)
            }
        }
    }
}
