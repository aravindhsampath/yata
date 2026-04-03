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
                let repo = LocalTodoRepository(modelContainer: modelContext.container)
                let vm = HomeViewModel(repository: repo)
                viewModel = vm
                await vm.performRollover()
                await vm.materializeRepeatingItems()
                await vm.loadAll()
            }
        }
    }
}

private struct HomeContentView: View {
    @Bindable var viewModel: HomeViewModel
    @AppStorage("doneListSize") private var doneListSize = 25

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                WeekStripView(
                    weekDates: viewModel.weekDates,
                    selectedDate: viewModel.selectedDate,
                    onSelectDate: { date in
                        Task { await viewModel.selectDate(date) }
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
            await viewModel.performRollover()
            await viewModel.materializeRepeatingItems()
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
                await viewModel.materializeRepeatingItems()
                await viewModel.loadAll()
            }
        }
        .task {
            // Midnight rollover timer
            while !Task.isCancelled {
                let delay = viewModel.secondsUntilMidnight + 1
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                viewModel.refreshWeekDates()
                await viewModel.performRollover()
                await viewModel.materializeRepeatingItems()
                await viewModel.loadAll()
            }
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [TodoItem.self, RepeatingItem.self], inMemory: true)
}
