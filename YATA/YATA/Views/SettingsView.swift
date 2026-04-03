import SwiftUI

struct SettingsView: View {
    @AppStorage("colorScheme") private var colorSchemePreference = ColorSchemePreference.system.rawValue
    @AppStorage("doneListSize") private var doneListSize = 25

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
                Section("Appearance") {
                    Picker("Color Scheme", selection: selectedPreference) {
                        ForEach(ColorSchemePreference.allCases) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Recently Done") {
                    Picker("Show last", selection: $doneListSize) {
                        ForEach(doneListOptions, id: \.self) { count in
                            Text("\(count) items").tag(count)
                        }
                    }
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
