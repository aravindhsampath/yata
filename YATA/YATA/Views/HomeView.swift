import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: HomeViewModel?

    var body: some View {
        Group {
            if let viewModel {
                HomeContentView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                let container = modelContext.container
                let repo = LocalTodoRepository(modelContainer: container)
                let vm = HomeViewModel(repository: repo)
                viewModel = vm
                await vm.performRollover()
                await vm.materializeRepeatingItems(using: container)
                await vm.loadAll()
            }
        }
    }
}

private struct HomeContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: HomeViewModel
    @AppStorage("doneListSize") private var doneListSize = 25

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                WeekStripView(
                    weekDates: viewModel.weekDates,
                    selectedDate: viewModel.selectedDate,
                    onSelectDate: { date in
                        Task {
                            await viewModel.selectDate(date, using: modelContext.container)
                        }
                    }
                )

                ForEach(Priority.allCases) { priority in
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
            let container = modelContext.container
            await viewModel.performRollover()
            await viewModel.materializeRepeatingItems(using: container)
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
                },
                onReschedule: { date in
                    Task { await viewModel.rescheduleItem(item, to: date) }
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
        .alert("Error", isPresented: $viewModel.hasError) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: doneListSize) {
            viewModel.doneListLimit = doneListSize
            Task { await viewModel.loadAll() }
        }
        .onAppear {
            viewModel.doneListLimit = doneListSize
            Task {
                let container = modelContext.container
                await viewModel.materializeRepeatingItems(using: container)
                await viewModel.loadAll()
            }
        }
        .task(id: "midnightRollover") {
            while !Task.isCancelled {
                let delay = viewModel.secondsUntilMidnight + 1 // 1s past midnight
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                let container = modelContext.container
                await viewModel.performRollover()
                await viewModel.materializeRepeatingItems(using: container)
                await viewModel.loadAll()
            }
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [TodoItem.self, RepeatingItem.self], inMemory: true)
}
