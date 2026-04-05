import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @AppStorage("doneListSize") private var doneListSize = 25
    @AppStorage("serverMode") private var serverMode = "local"
    @Environment(RepositoryProvider.self) private var repositoryProvider
    @Environment(\.modelContext) private var modelContext

    @State private var serverURLText = ""
    @State private var secretText = ""
    @State private var healthStatus: HealthCheckStatus = .idle
    @State private var connectionState: ConnectionState = .disconnected
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var selectedPreference: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: colorSchemePreference) ?? .system },
            set: { colorSchemePreference = $0.rawValue }
        )
    }

    private let doneListOptions = [10, 25, 50, 100]

    private enum HealthCheckStatus {
        case idle, checking, reachable, unreachable
    }

    private enum ConnectionState {
        case disconnected, authenticating, connected
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                appearanceSection
                recentlyDoneSection
                aboutSection
            }
            .navigationTitle("Settings")
            .overlay {
                if isSyncing {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Syncing...")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
        }
        .onAppear {
            // Restore UI state from persisted values
            if serverMode == "client" {
                connectionState = .connected
                healthStatus = .reachable
                if let urlString = KeychainHelper.loadString(forKey: "yata_server_url") {
                    serverURLText = urlString
                }
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            Picker("Mode", selection: $serverMode) {
                Text("Local").tag("local")
                Text("Client").tag("client")
            }
            .pickerStyle(.segmented)
            .onChange(of: serverMode) { oldValue, newValue in
                if newValue == "local" && oldValue == "client" {
                    repositoryProvider.disconnect()
                    connectionState = .disconnected
                    healthStatus = .idle
                    serverURLText = ""
                    secretText = ""
                }
            }

            if serverMode == "client" {
                clientConfigFields
            }
        }
    }

    @ViewBuilder
    private var clientConfigFields: some View {
        switch connectionState {
        case .disconnected:
            TextField("Server URL", text: $serverURLText)
                .textContentType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { checkHealth() }

            healthStatusRow

            if healthStatus == .reachable {
                SecureField("Secret", text: $secretText)
                    .onSubmit { authenticate() }

                Button("Authenticate") { authenticate() }
                    .disabled(secretText.isEmpty)
            }

        case .authenticating:
            ProgressView("Authenticating...")

        case .connected:
            connectedFields
        }
    }

    private var healthStatusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            switch healthStatus {
            case .idle:
                Text("Enter URL above")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .reachable:
                Label("Reachable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unreachable:
                Label("Unreachable", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var connectedFields: some View {
        HStack {
            Text("Status")
            Spacer()
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }

        if let lastSync = repositoryProvider.lastSyncTime() {
            LabeledContent("Last Sync", value: lastSync)
        }

        LabeledContent("Pending Mutations", value: "\(repositoryProvider.pendingMutationCount())")

        Button("Sync Now") {
            Task { await syncNow() }
        }

        Button("Disconnect", role: .destructive) {
            repositoryProvider.disconnect()
            serverMode = "local"
            connectionState = .disconnected
            healthStatus = .idle
            serverURLText = ""
            secretText = ""
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Color Scheme", selection: selectedPreference) {
                ForEach(ColorSchemePreference.allCases) { pref in
                    Text(pref.label).tag(pref)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var recentlyDoneSection: some View {
        Section("Recently Done") {
            Picker("Show last", selection: $doneListSize) {
                ForEach(doneListOptions, id: \.self) { count in
                    Text("\(count) items").tag(count)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "1.0.0")
        }
    }

    // MARK: - Actions

    private func checkHealth() {
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            healthStatus = .unreachable
            return
        }
        healthStatus = .checking
        Task {
            let ok = await APIClient.checkHealth(serverURL: url)
            healthStatus = ok ? .reachable : .unreachable
        }
    }

    private func authenticate() {
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: trimmed) else {
            showErrorMessage("Invalid server URL.")
            return
        }
        connectionState = .authenticating

        Task {
            do {
                let token = try await APIClient.authenticate(serverURL: serverURL, secret: secretText)
                repositoryProvider.switchToClient(serverURL: serverURL, token: token)
                await performInitialSync(serverURL: serverURL, token: token)
            } catch {
                showErrorMessage("Authentication failed: \(error.localizedDescription)")
                repositoryProvider.switchToLocal()
                serverMode = "local"
                connectionState = .disconnected
                healthStatus = .reachable
            }
        }
    }

    private func performInitialSync(serverURL: URL, token: String) async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let apiClient = APIClient(serverURL: serverURL, token: token)

            // Push all local TodoItems
            let localTodoRepo = LocalTodoRepository(modelContainer: modelContext.container)
            let allDates = [Date.distantPast...Date.distantFuture]
            // Push items for each priority
            for priority in Priority.allCases {
                let items = try await localTodoRepo.fetchItems(for: .now, priority: priority)
                for item in items {
                    let dateFormatter = Self.dateFormatter
                    let body = CreateItemRequest(
                        id: item.id,
                        title: item.title,
                        priority: item.priorityRawValue,
                        scheduledDate: dateFormatter.string(from: item.scheduledDate),
                        reminderDate: item.reminderDate.map { dateFormatter.string(from: $0) },
                        sortOrder: item.sortOrder,
                        sourceRepeatingId: item.sourceRepeatingID,
                        sourceRepeatingRuleName: item.sourceRepeatingRuleName
                    )
                    try? await (apiClient.requestNoContent(.createItem(body: body)) as Void)
                }
            }

            // Push all local RepeatingItems
            let localRepeatingRepo = LocalRepeatingRepository(modelContainer: modelContext.container)
            let repeatingItems = try await localRepeatingRepo.fetchItems()
            for item in repeatingItems {
                let dateFormatter = Self.dateFormatter
                let body = CreateRepeatingRequest(
                    id: item.id,
                    title: item.title,
                    frequency: item.frequencyRawValue,
                    scheduledTime: dateFormatter.string(from: item.scheduledTime),
                    scheduledDayOfWeek: item.scheduledDayOfWeek,
                    scheduledDayOfMonth: item.scheduledDayOfMonth,
                    scheduledMonth: item.scheduledMonth,
                    sortOrder: item.sortOrder,
                    defaultUrgency: item.defaultUrgencyRawValue
                )
                try? await (apiClient.requestNoContent(.createRepeating(body: body)) as Void)
            }

            // Pull to get server timestamps
            try await repositoryProvider.syncEngine?.fullSync()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)

            connectionState = .connected
            secretText = ""
        } catch {
            showErrorMessage("Initial sync failed: \(error.localizedDescription)")
            repositoryProvider.disconnect()
            serverMode = "local"
            connectionState = .disconnected
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await repositoryProvider.syncEngine?.fullSync()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        } catch {
            showErrorMessage("Sync failed: \(error.localizedDescription)")
        }
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

#Preview {
    let container = try! ModelContainer(for: TodoItem.self, RepeatingItem.self, PendingMutation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    SettingsView()
        .environment(RepositoryProvider.preview(container: container))
        .modelContainer(container)
}
