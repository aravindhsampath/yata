import SwiftUI
import SwiftData

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @AppStorage("doneListSize") private var doneListSize = 25
    @AppStorage("serverMode") private var serverMode = "local"
    @Environment(RepositoryProvider.self) private var repositoryProvider

    @State private var showConnectSheet = false
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

    var body: some View {
        NavigationStack {
            Form {
                storageSection
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
            .sheet(isPresented: $showConnectSheet, onDismiss: handleSheetDismiss) {
                ServerConnectSheet()
                    .environment(repositoryProvider)
            }
        }
        .onAppear {
            if repositoryProvider.isClientMode { refreshSyncStatus() }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            Picker("Mode", selection: $serverMode) {
                Text("Local").tag("local")
                Text("Server").tag("client")
            }
            .pickerStyle(.segmented)
            .onChange(of: serverMode) { oldValue, newValue in
                if newValue == "client" && !repositoryProvider.isClientMode {
                    // User switched the picker to Server but has no session —
                    // open the credential sheet.
                    showConnectSheet = true
                } else if newValue == "local" && oldValue == "client" {
                    Task { await repositoryProvider.disconnect() }
                }
            }

            if serverMode == "client" {
                if repositoryProvider.isClientMode {
                    connectedRows
                } else {
                    Button("Set up server…") { showConnectSheet = true }
                }
            }
        }
    }

    @ViewBuilder
    private var connectedRows: some View {
        if let username = repositoryProvider.connectedUsername {
            LabeledContent("Signed in as", value: username)
        }
        if let lastSync = repositoryProvider.lastSyncTime() {
            LabeledContent("Last sync", value: lastSync)
        }
        LabeledContent("Pending mutations", value: "\(repositoryProvider.pendingMutationCount())")

        syncStatusRow

        Button("Sync now") { Task { await syncNow() } }

        Button("Disconnect", role: .destructive) {
            Task {
                await repositoryProvider.disconnect()
                serverMode = "local"
            }
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

    private func handleSheetDismiss() {
        // If the user cancelled without connecting, revert the picker to Local.
        if !repositoryProvider.isClientMode {
            serverMode = "local"
        } else {
            refreshSyncStatus()
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
// A proper modal sheet for credential entry. This is the iOS pattern every
// serious client (Mail, 1Password, Proton, Bitwarden) uses for server sign-in:
// its own NavigationStack, a Cancel/Connect toolbar, keyboard lifecycle handled
// by the sheet itself. Dismissing the sheet — by success, by Cancel, or by
// swipe-down — tears the keyboard down because the entire scene goes away.

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

    /// Push local data to the server on first connect, then pull for
    /// server-authoritative timestamps. Kept here so the sheet owns its whole
    /// flow; errors surface inline and the sheet reverts isConnecting.
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
                    reminderDate: item.reminderDate.map { dateFormatter.string(from: $0) },
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
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
