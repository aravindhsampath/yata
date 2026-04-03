import SwiftUI

struct RepeatingAddEditSheet: View {
    let mode: RepeatingAddEditMode
    let onSave: (String, RepeatFrequency, Date, Int?, Int?, Int?) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var frequency: RepeatFrequency
    @State private var scheduledTime: Date
    @State private var selectedDayOfWeek: Weekday
    @State private var selectedDayOfMonth: Int
    @State private var selectedMonth: Int
    @FocusState private var isTitleFocused: Bool

    init(
        mode: RepeatingAddEditMode,
        onSave: @escaping (String, RepeatFrequency, Date, Int?, Int?, Int?) -> Void,
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
            _selectedDayOfWeek = State(initialValue: .monday)
            _selectedDayOfMonth = State(initialValue: 1)
            _selectedMonth = State(initialValue: 1)
        case .edit(let item):
            _title = State(initialValue: item.title)
            _frequency = State(initialValue: item.frequency)
            _scheduledTime = State(initialValue: item.scheduledTime)
            _selectedDayOfWeek = State(initialValue: Weekday(rawValue: item.scheduledDayOfWeek ?? 2) ?? .monday)
            _selectedDayOfMonth = State(initialValue: item.scheduledDayOfMonth ?? 1)
            _selectedMonth = State(initialValue: item.scheduledMonth ?? 1)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    TextField("What repeats?", text: $title, axis: .vertical)
                        .lineLimit(3...)
                        .font(.body)
                        .padding()
                        .background(.quaternary, in: .rect(cornerRadius: 12))
                        .focused($isTitleFocused)

                    frequencySection

                    scheduleSection

                    if isEditing, let onDelete {
                        Button("Delete Task", systemImage: "trash", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
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

    // MARK: - Frequency picker

    private var frequencySection: some View {
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
    }

    // MARK: - Conditional schedule pickers

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch frequency {
            case .daily, .everyWorkday:
                timePicker

            case .weekly:
                dayOfWeekPicker
                timePicker

            case .monthly:
                dayOfMonthPicker
                timePicker

            case .yearly:
                monthPicker
                dayOfMonthPicker
                timePicker
            }
        }
        .animation(.easeInOut(duration: 0.2), value: frequency)
    }

    private var timePicker: some View {
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
    }

    private var dayOfWeekPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day")
                .font(YATATheme.captionFont)
                .foregroundStyle(.secondary)

            Picker("Day", selection: $selectedDayOfWeek) {
                ForEach(Weekday.allCases) { day in
                    Text(day.shortLabel).tag(day)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dayOfMonthPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day of Month")
                .font(YATATheme.captionFont)
                .foregroundStyle(.secondary)

            Picker("Day", selection: $selectedDayOfMonth) {
                ForEach(1...28, id: \.self) { day in
                    Text("\(day)").tag(day)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 100)
        }
    }

    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Month")
                .font(YATATheme.captionFont)
                .foregroundStyle(.secondary)

            Picker("Month", selection: $selectedMonth) {
                ForEach(1...12, id: \.self) { m in
                    Text(Calendar.current.monthSymbols[m - 1]).tag(m)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 100)
        }
    }

    // MARK: - Actions

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let dayOfWeek: Int? = frequency == .weekly ? selectedDayOfWeek.rawValue : nil
        let dayOfMonth: Int? = (frequency == .monthly || frequency == .yearly) ? selectedDayOfMonth : nil
        let month: Int? = frequency == .yearly ? selectedMonth : nil

        onSave(trimmed, frequency, scheduledTime, dayOfWeek, dayOfMonth, month)
        dismiss()
    }

    private static func defaultTime() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }
}
