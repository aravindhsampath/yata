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
                let container = modelContext.container
                let repo = LocalRepeatingRepository(modelContainer: container)
                let todoRepo = LocalTodoRepository(modelContainer: container)
                let vm = RepeatingViewModel(repository: repo, todoRepository: todoRepo)
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
                onSave: { data in
                    item.title = data.title
                    item.frequency = data.frequency
                    item.scheduledTime = data.scheduledTime
                    item.scheduledDayOfWeek = data.dayOfWeek
                    item.scheduledDayOfMonth = data.dayOfMonth
                    item.scheduledMonth = data.month
                    item.defaultUrgency = data.defaultUrgency
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
                onSave: { data in
                    Task {
                        await viewModel.addItem(
                            title: data.title,
                            frequency: data.frequency,
                            scheduledTime: data.scheduledTime,
                            dayOfWeek: data.dayOfWeek,
                            dayOfMonth: data.dayOfMonth,
                            month: data.month,
                            defaultUrgency: data.defaultUrgency
                        )
                    }
                },
                onDelete: nil
            )
        }
        .alert("Error", isPresented: $viewModel.hasError) {
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
