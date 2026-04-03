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
    @State private var activePicker: SchedulePicker?
    @FocusState private var isTitleFocused: Bool

    private enum SchedulePicker: Identifiable {
        case time, dayOfMonth, month
        var id: String {
            switch self {
            case .time: "time"
            case .dayOfMonth: "dayOfMonth"
            case .month: "month"
            }
        }
    }

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
            .scrollDismissesKeyboard(.interactively)
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
            .sheet(item: $activePicker) { picker in
                pickerSheet(for: picker)
            }
        }
        .presentationDetents([.large])
        .task { isTitleFocused = true }
        .onChange(of: frequency) {
            isTitleFocused = false
        }
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

    // MARK: - Schedule section (frequency-dependent)

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch frequency {
            case .daily, .everyWorkday:
                chipRow(items: [
                    ("Time", formattedTime, .time),
                ])

            case .weekly:
                dayOfWeekPicker
                chipRow(items: [
                    ("Time", formattedTime, .time),
                ])

            case .monthly:
                chipRow(items: [
                    ("Day", "\(selectedDayOfMonth)", .dayOfMonth),
                    ("Time", formattedTime, .time),
                ])

            case .yearly:
                chipRow(items: [
                    ("Month", shortMonthName, .month),
                    ("Day", "\(selectedDayOfMonth)", .dayOfMonth),
                    ("Time", formattedTime, .time),
                ])
            }
        }
        .animation(.easeInOut(duration: 0.2), value: frequency)
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

    // MARK: - Tappable chip row

    private func chipRow(items: [(label: String, value: String, picker: SchedulePicker)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.label) { item in
                VStack(spacing: 6) {
                    Text(item.label)
                        .font(YATATheme.captionFont)
                        .foregroundStyle(.secondary)

                    Button(action: { activePicker = item.picker }) {
                        HStack(spacing: 6) {
                            Text(item.value)
                                .font(.title3.weight(.medium).monospacedDigit())
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
    }

    // MARK: - Picker sheets

    @ViewBuilder
    private func pickerSheet(for picker: SchedulePicker) -> some View {
        NavigationStack {
            VStack {
                switch picker {
                case .time:
                    DatePicker(
                        "Time",
                        selection: $scheduledTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)

                case .dayOfMonth:
                    Picker("Day", selection: $selectedDayOfMonth) {
                        ForEach(1...28, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.wheel)

                case .month:
                    Picker("Month", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(Calendar.current.monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .pickerStyle(.wheel)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activePicker = nil }
                }
            }
        }
        .presentationDetents([.height(280)])
    }

    // MARK: - Helpers

    private var formattedTime: String {
        scheduledTime.formatted(.dateTime.hour().minute())
    }

    private var shortMonthName: String {
        Calendar.current.shortMonthSymbols[selectedMonth - 1]
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
