import SwiftUI

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Color Scheme", selection: $colorSchemePreference) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
