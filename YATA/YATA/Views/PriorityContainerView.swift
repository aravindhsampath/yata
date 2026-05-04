import SwiftUI
import UniformTypeIdentifiers

struct PriorityContainerView: View {
    let priority: Priority
    @Bindable var viewModel: HomeViewModel

    private var items: [TodoItem] { viewModel.items(for: priority) }

    var body: some View {
        VStack(spacing: 0) {
            // Mono-caps section header. The label sits in `textDim`; the
            // right-aligned meta ("N open") sits one tier quieter in
            // `textMute`. Hierarchy lives entirely in typography here —
            // no per-priority colored fill on the card.
            HStack(alignment: .firstTextBaseline) {
                Text(priority.label.uppercased())
                    .font(YATAFont.mono(10))
                    .tracking(1.4) // 0.14em on 10pt ≈ 1.4pt absolute
                    .foregroundStyle(Color.yataTextDim)
                Spacer()
                Text(metaLabel)
                    .font(YATAFont.mono(10))
                    .tracking(0.6)
                    .foregroundStyle(Color.yataTextMute)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 8)

            // Rows + insertion indicators + Add row, all sharing tight
            // 2pt vertical gap. Rows do their own internal padding.
            VStack(spacing: 2) {
                ForEach(items) { item in
                    if let index = items.firstIndex(where: { $0.id == item.id }),
                       viewModel.dropTarget?.priority == priority,
                       viewModel.dropTarget?.index == index {
                        insertionIndicator
                    }

                    TodoPillView(
                        item: item,
                        justDropped: viewModel.justDroppedItemID == item.id,
                        lanePriority: priority,
                        onMarkDone: { Task { await viewModel.markDone(item) } },
                        onEdit: { viewModel.editingItem = item },
                        onDelete: { Task { await viewModel.deleteItem(item) } },
                        onDragStart: { viewModel.startDrag(itemID: item.id) },
                        onRescheduleTomorrow: { Task { await viewModel.rescheduleToTomorrow(item) } }
                    )
                }

                if viewModel.dropTarget?.priority == priority
                    && viewModel.dropTarget?.index == items.count {
                    insertionIndicator
                }

                addRow
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: YATATheme.Radius.section, style: .continuous)
                .fill(Color.yataSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: YATATheme.Radius.section, style: .continuous)
                .stroke(Color.yataHairline, lineWidth: 1)
        )
        .onDrop(of: [UTType.text], delegate: PriorityDropDelegate(
            priority: priority,
            viewModel: viewModel
        ))
        .animation(.easeInOut(duration: 0.2), value: viewModel.dropTarget)
    }

    // MARK: - Subviews

    /// Right-aligned "N open" meta in mono caps. Reads as quietly informative
    /// next to the section label — the user gets a glanceable count without
    /// the eye darting to a colored badge.
    private var metaLabel: String {
        let count = items.count
        return count == 1 ? "1 open" : "\(count) open"
    }

    /// Collapsed Add row — dashed-circle plus glyph + label in `textDim`.
    /// Visually reads as an affordance, not a chip; matches the design's
    /// "tap to expand into inline editor" pattern even though we still
    /// route to the existing AddEditSheet for now.
    private var addRow: some View {
        Button(action: addTapped) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            Color.yataTextMute,
                            style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.yataTextMute)
                }
                .frame(width: 22, height: 22)

                Text("Add")
                    .font(YATAFont.text(15))
                    .foregroundStyle(Color.yataTextDim)

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: YATATheme.RowHeight.addRow)
            .contentShape(
                RoundedRectangle(cornerRadius: YATATheme.Radius.row, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to \(priority.label)")
    }

    /// Insertion indicator while drag-dropping. 14pt rounded rect with a
    /// dashed accent stroke, matching the new row geometry exactly so the
    /// "this is where it'll land" mental model holds.
    private var insertionIndicator: some View {
        RoundedRectangle(cornerRadius: YATATheme.Radius.row, style: .continuous)
            .strokeBorder(
                Color.yataAccent.opacity(0.55),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .frame(height: YATATheme.RowHeight.todo)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func addTapped() {
        viewModel.addingToPriority = priority
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
        viewModel.dropTarget = nil // Hide insertion indicator immediately

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String,
                  let uuid = UUID(uuidString: idString) else {
                Task { @MainActor in viewModel.endDrag() }
                return
            }
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

        // Each pill takes pillHeight + pillSpacing, offset by lane label + container padding
        let labelHeight: Double = 20 + YATATheme.pillSpacing // caption font ~16pt + padding
        let containerPadding = YATATheme.containerPadding
        let itemSlotHeight = YATATheme.pillHeight + YATATheme.pillSpacing

        // Y position relative to the first item's top edge (after lane label)
        let relativeY = info.location.y - containerPadding - labelHeight

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
