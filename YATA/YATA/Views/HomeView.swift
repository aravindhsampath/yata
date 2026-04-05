import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: HomeViewModel?
    @State private var permissionManager = NotificationPermissionManager()

    var body: some View {
        Group {
            if let viewModel {
                HomeContentView(viewModel: viewModel, permissionManager: permissionManager)
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
        .onReceive(NotificationCenter.default.publisher(for: .yataDataDidChange)) { _ in
            guard let viewModel else { return }
            Task { await viewModel.loadAll() }
        }
    }
}

private struct HomeContentView: View {
    @Bindable var viewModel: HomeViewModel
    let permissionManager: NotificationPermissionManager
    @AppStorage("doneListSize") private var doneListSize = 25
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var weekStrip: some View {
        WeekStripView(
            weekDates: viewModel.weekDates,
            selectedDate: viewModel.selectedDate,
            taskCounts: viewModel.weekTaskCounts,
            onSelectDate: { date in
                Task { await viewModel.selectDate(date) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            weekStrip
                .padding(.horizontal, YATATheme.pillPadding)
                .padding(.bottom, 8)

        ScrollView {
            LazyVStack(spacing: 16) {
                if sizeClass == .regular {
                    // iPad: side-by-side Kanban layout
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Priority.allCases.reversed()) { priority in
                            PriorityContainerView(
                                priority: priority,
                                viewModel: viewModel
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    // iPhone: vertical stack
                    ForEach(Priority.allCases.reversed()) { priority in
                        PriorityContainerView(
                            priority: priority,
                            viewModel: viewModel
                        )
                    }
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
        } // VStack
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
                },
                sourceRuleName: item.sourceRepeatingRuleName,
                permissionManager: permissionManager
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
                onDelete: nil,
                permissionManager: permissionManager
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
        .onKeyPress(characters: .init(charactersIn: "n"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            viewModel.addingToPriority = .high
            return .handled
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
