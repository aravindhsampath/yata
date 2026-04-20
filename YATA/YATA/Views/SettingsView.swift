import SwiftUI
import SwiftData

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @AppStorage("doneListSize") private var doneListSize = 25
    /// Reactive source of truth for connected-vs-local state. `switchToClient`
    /// writes this via UserDefaults, so @AppStorage picks up changes from any
    /// path (sheet success, disconnect, relaunch). The view re-renders in
    /// lockstep.
    @AppStorage("serverMode") private var serverMode = "local"
    @Environment(RepositoryProvider.self) private var repositoryProvider

    @State private var showConnectSheet = false
    @State private var showDisconnectConfirm = false
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var syncStatusValue: SyncStatus = .ok

    private var selectedPreference: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: colorSchemePreference) ?? .system },
            set: { colorSchemePreference = $0.rawValue }
        )
    }

    private let doneListOptions = [10, 25, 50, 100]

    private var isConnected: Bool { serverMode == "client" }

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                appearanceSection
                recentlyDoneSection
                aboutSection
            }
            .navigationTitle("Settings")
            .overlay {
                if isSyncing {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Syncing…")
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
            .alert("Disconnect from server?", isPresented: $showDisconnectConfirm) {
                Button("Disconnect", role: .destructive) { disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your tasks stay on this device. Any pending changes that haven't synced yet will be lost.")
            }
            .sheet(isPresented: $showConnectSheet) {
                ServerConnectSheet()
                    .environment(repositoryProvider)
            }
        }
        .onAppear {
            if isConnected { refreshSyncStatus() }
        }
    }

    // MARK: - Sync section

    @ViewBuilder
    private var syncSection: some View {
        Section {
            if isConnected {
                connectedRows
            } else {
                Button {
                    showConnectSheet = true
                } label: {
                    Label("Connect to server…", systemImage: "icloud.and.arrow.up")
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            if !isConnected {
                Text("Local mode: tasks live only on this device. Connect to a self-hosted YATA server to sync across devices.")
            }
        }
    }

    @ViewBuilder
    private var connectedRows: some View {
        if let host = serverHost {
            LabeledContent("Server", value: host)
        }
        if let username = repositoryProvider.connectedUsername {
            LabeledContent("Signed in as", value: username)
        }
        if let lastSync = repositoryProvider.lastSyncTime() {
            LabeledContent("Last sync", value: lastSync)
        }

        syncStatusRow

        Button {
            Task { await syncNow() }
        } label: {
            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
        }

        Button(role: .destructive) {
            showDisconnectConfirm = true
        } label: {
            Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch syncStatusValue {
        case .ok:
            EmptyView()
        case .retrying(let failures, let nextRetryIn):
            Text("Retrying (\(failures) failures, next in \(Int(nextRetryIn))s)")
                .foregroundStyle(.orange)
                .font(.footnote)
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

    private var serverHost: String? {
        guard let raw = KeychainHelper.loadString(forKey: "yata_server_url"),
              let url = URL(string: raw) else { return nil }
        return url.host ?? raw
    }

    // MARK: - Other sections

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

    /// Flip the UI to disconnected immediately, then clean up in the
    /// background. Waiting on the pre-teardown sync made the tap feel
    /// unresponsive; the user already confirmed the intent in the alert.
    private func disconnect() {
        serverMode = "local"
        Task { await repositoryProvider.disconnect() }
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
            errorMessage = "Sync failed: \(error.localizedDescription)"
            showError = true
        }
    }

    private func refreshSyncStatus() {
        Task {
            if let engine = repositoryProvider.syncEngine {
                syncStatusValue = await engine.syncStatus()
            }
        }
    }
}

// MARK: - ServerConnectSheet
//
// Modal credential entry. Its own NavigationStack with Cancel / Connect in
// the nav bar. Dismissing the sheet (success, Cancel, or swipe-down) tears
// the keyboard down along with the scene — no responder-chain plumbing
// required.

struct ServerConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RepositoryProvider.self) private var repositoryProvider
    @Environment(\.modelContext) private var modelContext

    @State private var urlText = ""
    @State private var usernameText = ""
    @State private var passwordText = ""
    @State private var isPasswordVisible = false
    @State private var isConnecting = false
    @State private var errorText: String?

    @FocusState private var focus: Field?

    enum Field: Hashable { case url, username, password }

    private var canConnect: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !usernameText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !passwordText.isEmpty &&
        !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://yata.example.com", text: $urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                }

                Section("Account") {
                    TextField("Username", text: $usernameText)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $passwordText)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: $passwordText)
                                    .textContentType(.password)
                            }
                        }
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canConnect { attempt() } }

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect to Server")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isConnecting)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConnecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") { attempt() }
                            .disabled(!canConnect)
                            .bold()
                    }
                }
            }
            .overlay {
                if isConnecting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
                }
            }
        }
        .onAppear { focus = .url }
    }

    // MARK: - Connect flow

    private func attempt() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: trimmed),
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorText = "Enter a full URL starting with http:// or https://"
            focus = .url
            return
        }
        errorText = nil
        isConnecting = true

        let username = usernameText.trimmingCharacters(in: .whitespaces)
        let password = passwordText

        Task {
            // Health probe first so we can distinguish unreachable from unauthorized.
            let reachable = await APIClient.checkHealth(serverURL: serverURL)
            guard reachable else {
                errorText = "Can't reach \(serverURL.host ?? "server"). Check the URL and your connection."
                isConnecting = false
                focus = .url
                return
            }

            // Authenticate.
            do {
                let token = try await APIClient.authenticate(
                    serverURL: serverURL, username: username, password: password
                )
                repositoryProvider.switchToClient(
                    serverURL: serverURL, username: username, token: token
                )
                await performInitialSync(serverURL: serverURL, token: token)
                dismiss()
            } catch APIError.unauthorized {
                errorText = "Incorrect username or password."
                passwordText = ""
                isConnecting = false
                focus = .password
            } catch {
                errorText = "Authentication failed: \(error.localizedDescription)"
                isConnecting = false
                focus = .password
            }
        }
    }

    private func performInitialSync(serverURL: URL, token: String) async {
        do {
            let apiClient = APIClient(serverURL: serverURL, token: token)
            let dateFormatter = Self.dateFormatter

            let allItems = try modelContext.fetch(FetchDescriptor<TodoItem>())
            for item in allItems {
                let body = CreateItemRequest(
                    id: item.id,
                    title: item.title,
                    priority: item.priorityRawValue,
                    scheduledDate: dateFormatter.string(from: item.scheduledDate),
                    // reminder_date is a timestamp, not a date. Must match
                    // the ISO8601 format used everywhere else or the server
                    // rejects it with a validation error.
                    reminderDate: item.reminderDate.map { DateFormatters.iso8601DateTime.string(from: $0) },
                    sortOrder: item.sortOrder,
                    sourceRepeatingId: item.sourceRepeatingID,
                    sourceRepeatingRuleName: item.sourceRepeatingRuleName
                )
                try? await (apiClient.requestNoContent(.createItem(body: body)) as Void)
            }

            let localRepeatingRepo = LocalRepeatingRepository(modelContainer: modelContext.container)
            let repeatingItems = try localRepeatingRepo.fetchItems()
            for item in repeatingItems {
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

            try await repositoryProvider.syncEngine?.fullSync()
            NotificationCenter.default.post(name: .yataDataDidChange, object: nil)
        } catch {
            errorText = "Initial sync failed: \(error.localizedDescription)"
            await repositoryProvider.disconnect()
            isConnecting = false
        }
    }

    /// Same local-tz rule as `DateFormatters.dateOnly` — the initial
    /// backfill sends `scheduled_date` in the same format the rest of
    /// the app round-trips.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - Preview

#Preview {
    let container = try! ModelContainer(
        for: TodoItem.self, RepeatingItem.self, PendingMutation.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    SettingsView()
        .environment(RepositoryProvider.preview(container: container))
        .modelContainer(container)
}
