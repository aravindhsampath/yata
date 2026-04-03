import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: HomeViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    HomeContentView(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("TO DO")
        }
        .task {
            if viewModel == nil {
                let repo = LocalTodoRepository(modelContainer: modelContext.container)
                let vm = HomeViewModel(repository: repo)
                viewModel = vm
                await vm.loadAll()
            }
        }
    }
}

private struct HomeContentView: View {
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Priority.allCases.reversed()) { priority in
                    PriorityContainerView(
                        priority: priority,
                        viewModel: viewModel
                    )
                }
                DoneSectionView(viewModel: viewModel)
            }
            .padding(.horizontal, YATATheme.pillPadding)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.loadAll()
        }
        .sheet(item: $viewModel.editingItem) { item in
            AddEditSheet(
                mode: .edit(item),
                onSave: { title, reminder in
                    item.title = title
                    item.reminderDate = reminder
                    Task { await viewModel.updateItem(item) }
                },
                onDelete: {
                    Task { await viewModel.deleteItem(item) }
                }
            )
        }
        .sheet(item: $viewModel.addingToPriority) { priority in
            AddEditSheet(
                mode: .add,
                onSave: { title, reminder in
                    Task {
                        await viewModel.addItem(
                            title: title,
                            priority: priority,
                            reminderDate: reminder
                        )
                    }
                },
                onDelete: nil
            )
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
