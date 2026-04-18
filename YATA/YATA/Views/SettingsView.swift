import SwiftUI
import SwiftData
import UIKit

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
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                // Tap anywhere outside a field dismisses the keyboard. We use
                // simultaneousGesture so TextField/Button taps still work —
                // the field just briefly blurs and re-focuses, which is
                // acceptable and matches Apple's own Mail/Notes behavior.
                TapGesture().onEnded {
                    print("[YATA kbd] tap-outside gesture")
                    dismissKeyboard()
                }
            )
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        print("[YATA kbd] Done toolbar button tapped")
                        dismissKeyboard()
                    }
                }
            }
            .onChange(of: connectionState) { old, new in
                print("[YATA kbd] connectionState changed: \(old) → \(new)")
                // Any transition out of .disconnected means the credential
                // fields are gone — aggressively clear any orphaned keyboard.
                if new != .disconnected {
                    dismissKeyboard()
                    // Also schedule one more tick later, in case the view
                    // rebuild hasn't propagated to the responder chain yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        dismissKeyboard()
                    }
                }
            }
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
        Section("Storage") {
            Picker("Mode", selection: $serverMode) {
                Text("Local").tag("local")
                Text("Server").tag("client")
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
                        authErrorMessage = nil
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
            // All three credentials on one form. The Connect button validates
            // everything in one shot (URL reachability + authentication).
            TextField("Server URL", text: $serverURLText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .serverURL)
                .submitLabel(.next)
                .onSubmit { focusedField = .username }

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
                .onSubmit { if canConnect { authenticate() } }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
            }

            Button("Connect") { authenticate() }
                .disabled(!canConnect)
                .accessibilityHint("Verifies the URL and signs in with the username and password above.")

            if let authErrorMessage {
                Text(authErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

        case .authenticating:
            HStack(spacing: 12) {
                ProgressView()
                Text("Connecting…")
            }

        case .connected:
            connectedFields
        }
    }

    /// Cheap pre-flight check for the Connect button — the server handles the
    /// real validation. We only want to gray out the button until the user has
    /// typed something into every field.
    private var canConnect: Bool {
        !serverURLText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !usernameText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !passwordText.isEmpty
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

    /// Bulletproof keyboard dismissal. On iOS 26 we've observed that just
    /// clearing @FocusState or sending resignFirstResponder to a nil target
    /// doesn't always tear down the keyboard — there's an orphan state where
    /// the TextField has been torn down from the view hierarchy but the
    /// keyboard remains. Calling `endEditing(true)` on each scene window
    /// explicitly ends editing, including for orphaned/resign-refused
    /// responders. This is UIKit's guaranteed path.
    private func dismissKeyboard() {
        focusedField = nil
        let sent = UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        var endedCount = 0
        var windowCount = 0
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                windowCount += 1
                if window.endEditing(true) { endedCount += 1 }
            }
        }
        print("[YATA kbd] dismissKeyboard sendAction=\(sent) windows=\(windowCount) endedEditing=\(endedCount)")
    }

    private func authenticate() {
        print("[YATA kbd] authenticate() tapped — state=\(connectionState) focus=\(String(describing: focusedField))")
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: trimmed), let scheme = serverURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            authErrorMessage = "Enter a full URL starting with http:// or https://"
            focusedField = .serverURL
            return
        }
        authErrorMessage = nil
        dismissKeyboard()    // tuck the keyboard away while we work
        connectionState = .authenticating
        print("[YATA kbd] state → .authenticating")

        let username = usernameText.trimmingCharacters(in: .whitespaces)
        let password = passwordText
        Task {
            // 1. Health check — distinguishes "server unreachable" from "bad credentials".
            let reachable = await APIClient.checkHealth(serverURL: serverURL)
            guard reachable else {
                authErrorMessage = "Can't reach \(serverURL.host ?? "server"). Check the URL and your connection."
                connectionState = .disconnected
                healthStatus = .unreachable
                focusedField = .serverURL
                return
            }

            // 2. Authenticate.
            do {
                let token = try await APIClient.authenticate(serverURL: serverURL, username: username, password: password)
                print("[YATA kbd] auth OK — switching to client, running initial sync")
                repositoryProvider.switchToClient(serverURL: serverURL, username: username, token: token)
                await performInitialSync(serverURL: serverURL, token: token)
                print("[YATA kbd] initial sync complete — state=\(connectionState)")
                dismissKeyboard()    // belt-and-suspenders post-success
            } catch APIError.unauthorized {
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
