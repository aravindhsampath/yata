import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @AppStorage("doneListSize") private var doneListSize = 25
    @AppStorage("serverMode") private var serverMode = "local"
    @Environment(RepositoryProvider.self) private var repositoryProvider
    @Environment(\.modelContext) private var modelContext

    @State private var serverURLText = ""
    @State private var usernameText = ""
    @State private var passwordText = ""
    @State private var isPasswordVisible = false
    @State private var healthStatus: HealthCheckStatus = .idle
    @State private var connectionState: ConnectionState = .disconnected
    @State private var isSyncing = false
    @State private var authErrorMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var syncStatusValue: SyncStatus = .ok
    @FocusState private var focusedField: CredentialField?

    private enum CredentialField: Hashable { case serverURL, username, password }

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
                if let username = KeychainHelper.loadString(forKey: "yata_username") {
                    usernameText = username
                }
                refreshSyncStatus()
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
                    Task {
                        await repositoryProvider.disconnect()
                        connectionState = .disconnected
                        healthStatus = .idle
                        serverURLText = ""
                        usernameText = ""
                        passwordText = ""
                    }
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
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .serverURL)
                .submitLabel(.next)
                .onSubmit {
                    checkHealth()
                    if healthStatus != .unreachable { focusedField = .username }
                }

            healthStatusRow

            if healthStatus == .reachable {
                TextField("Username", text: $usernameText)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }

                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField("Password", text: $passwordText)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("Password", text: $passwordText)
                                .textContentType(.password)
                        }
                    }
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { authenticate() }

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                }

                Button("Authenticate") { authenticate() }
                    .disabled(usernameText.isEmpty || passwordText.isEmpty)
                    .accessibilityHint("Signs in with the username and password above.")

                if let authErrorMessage {
                    Text(authErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
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

        if let username = repositoryProvider.connectedUsername {
            LabeledContent("Signed in as", value: username)
        }

        if let lastSync = repositoryProvider.lastSyncTime() {
            LabeledContent("Last Sync", value: lastSync)
        }

        LabeledContent("Pending Mutations", value: "\(repositoryProvider.pendingMutationCount())")

        syncStatusRow

        Button("Sync Now") {
            Task { await syncNow() }
        }

        Button("Disconnect", role: .destructive) {
            Task {
                await repositoryProvider.disconnect()
                serverMode = "local"
                connectionState = .disconnected
                healthStatus = .idle
                serverURLText = ""
                usernameText = ""
                passwordText = ""
            }
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch syncStatusValue {
        case .ok:
            EmptyView()
        case .retrying(let failures, let nextRetryIn):
            HStack {
                Text("Retrying (\(failures) failures, next in \(Int(nextRetryIn))s)")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        case .halted(let failures):
            HStack {
                Text("Sync halted after \(failures) failures")
                    .foregroundStyle(.red)
                    .font(.footnote)
                Spacer()
                Button("Retry") {
                    Task {
                        await repositoryProvider.syncEngine?.resetBackoff()
                        await syncNow()
                    }
                }
                .font(.footnote)
            }
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
            authErrorMessage = "Invalid server URL."
            return
        }
        authErrorMessage = nil
        connectionState = .authenticating

        let username = usernameText
        let password = passwordText
        Task {
            do {
                let token = try await APIClient.authenticate(serverURL: serverURL, username: username, password: password)
                repositoryProvider.switchToClient(serverURL: serverURL, username: username, token: token)
                await performInitialSync(serverURL: serverURL, token: token)
            } catch APIError.unauthorized {
                // Expected failure: wrong credentials. Inline message, keep focus.
                authErrorMessage = "Incorrect username or password."
                passwordText = ""
                connectionState = .disconnected
                healthStatus = .reachable
                focusedField = .password
            } catch {
                authErrorMessage = "Authentication failed: \(error.localizedDescription)"
                connectionState = .disconnected
                healthStatus = .reachable
                focusedField = .password
            }
        }
    }

    private func performInitialSync(serverURL: URL, token: String) async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let apiClient = APIClient(serverURL: serverURL, token: token)

            // Push all local TodoItems
            let allItemsDescriptor = FetchDescriptor<TodoItem>()
            let allItems = try modelContext.fetch(allItemsDescriptor)
            let dateFormatter = Self.dateFormatter
            for item in allItems {
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

            // Push all local RepeatingItems
            let localRepeatingRepo = LocalRepeatingRepository(modelContainer: modelContext.container)
            let repeatingItems = try localRepeatingRepo.fetchItems()
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
            passwordText = ""
        } catch {
            showErrorMessage("Initial sync failed: \(error.localizedDescription)")
            await repositoryProvider.disconnect()
            serverMode = "local"
            connectionState = .disconnected
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer {
            isSyncing = false
            refreshSyncStatus()
        }
        do {
            try await repositoryProvider.syncEngine?.fullSync()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        } catch {
            showErrorMessage("Sync failed: \(error.localizedDescription)")
        }
    }

    private func refreshSyncStatus() {
        Task {
            if let engine = repositoryProvider.syncEngine {
                syncStatusValue = await engine.syncStatus()
            }
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
