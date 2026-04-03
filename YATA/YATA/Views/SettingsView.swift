import SwiftUI

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue

    private var selectedPreference: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: colorSchemePreference) ?? .system },
            set: { colorSchemePreference = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Color Scheme", selection: selectedPreference) {
                        ForEach(ColorSchemePreference.allCases) { pref in
                            Text(pref.label).tag(pref)
                        }
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
