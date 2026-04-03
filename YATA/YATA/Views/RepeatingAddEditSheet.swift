import SwiftUI

struct RepeatingAddEditSheet: View {
    let mode: RepeatingAddEditMode
    let onSave: (String, RepeatFrequency, Date) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var frequency: RepeatFrequency
    @State private var scheduledTime: Date
    @FocusState private var isTitleFocused: Bool

    init(
        mode: RepeatingAddEditMode,
        onSave: @escaping (String, RepeatFrequency, Date) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete

        switch mode {
        case .add:
            _title = State(initialValue: "")
            _frequency = State(initialValue: .daily)
            _scheduledTime = State(initialValue: Self.defaultTime())
        case .edit(let item):
            _title = State(initialValue: item.title)
            _frequency = State(initialValue: item.frequency)
            _scheduledTime = State(initialValue: item.scheduledTime)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("What repeats?", text: $title, axis: .vertical)
                    .lineLimit(3...)
                    .font(.body)
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                    .focused($isTitleFocused)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Frequency")
                        .font(YATATheme.captionFont)
                        .foregroundStyle(.secondary)

                    Picker("Frequency", selection: $frequency) {
                        ForEach(RepeatFrequency.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Time")
                        .font(YATATheme.captionFont)
                        .foregroundStyle(.secondary)

                    DatePicker(
                        "Time",
                        selection: $scheduledTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .frame(height: 100)
                }

                if isEditing, let onDelete {
                    Button("Delete Task", systemImage: "trash", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle(isEditing ? "Edit Repeating" : "New Repeating")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .task { isTitleFocused = true }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, frequency, scheduledTime)
        dismiss()
    }

    private static func defaultTime() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }
}
