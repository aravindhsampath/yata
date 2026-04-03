import SwiftUI
import SwiftData

struct RepeatingView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: RepeatingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                RepeatingContentView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                let repo = LocalRepeatingRepository(modelContainer: modelContext.container)
                let vm = RepeatingViewModel(repository: repo)
                viewModel = vm
                await vm.loadAll()
            }
        }
    }
}

private struct RepeatingContentView: View {
    @Bindable var viewModel: RepeatingViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Text("REPEATING")
                    .font(YATATheme.titleFont)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)

                VStack(spacing: YATATheme.pillSpacing) {
                    addButton

                    ForEach(viewModel.items) { item in
                        RepeatingPillView(
                            item: item,
                            onEdit: { viewModel.editingItem = item },
                            onDelete: { Task { await viewModel.deleteItem(item) } }
                        )
                    }
                }
                .padding(YATATheme.containerPadding)
                .containerStyle(color: YATATheme.repeatingBackgroundColor)
            }
            .padding(.horizontal, YATATheme.pillPadding)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.loadAll()
        }
        .sheet(item: $viewModel.editingItem) { item in
            RepeatingAddEditSheet(
                mode: .edit(item),
                onSave: { title, frequency, time in
                    item.title = title
                    item.frequency = frequency
                    item.scheduledTime = time
                    Task { await viewModel.updateItem(item) }
                },
                onDelete: {
                    Task { await viewModel.deleteItem(item) }
                }
            )
        }
        .sheet(isPresented: $viewModel.isAdding) {
            RepeatingAddEditSheet(
                mode: .add,
                onSave: { title, frequency, time in
                    Task {
                        await viewModel.addItem(
                            title: title,
                            frequency: frequency,
                            scheduledTime: time
                        )
                    }
                },
                onDelete: nil
            )
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var addButton: some View {
        Button(action: { viewModel.isAdding = true }) {
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
}

#Preview {
    RepeatingView()
        .modelContainer(for: RepeatingItem.self, inMemory: true)
}
