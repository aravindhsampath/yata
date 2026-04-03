import SwiftUI

struct AddEditSheet: View {
    let mode: AddEditMode
    let onSave: (String, Date?) -> Void
    let onDelete: (() -> Void)?
    let onReschedule: ((Date) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var reminderDate: Date?
    @State private var showReminderPicker = false
    @State private var showReschedulePicker = false
    @State private var rescheduleDate: Date = Calendar.current.startOfDay(for: .now)
    @FocusState private var isTitleFocused: Bool

    init(
        mode: AddEditMode,
        onSave: @escaping (String, Date?) -> Void,
        onDelete: (() -> Void)?,
        onReschedule: ((Date) -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        self.onReschedule = onReschedule

        switch mode {
        case .add:
            _title = State(initialValue: "")
            _reminderDate = State(initialValue: nil)
        case .edit(let item):
            _title = State(initialValue: item.title)
            _reminderDate = State(initialValue: item.reminderDate)
            _rescheduleDate = State(initialValue: item.scheduledDate)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("What needs doing?", text: $title, axis: .vertical)
                    .lineLimit(3...)
                    .font(.body)
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                    .focused($isTitleFocused)

                reminderRow

                if isEditing, onReschedule != nil {
                    rescheduleRow
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
            .navigationTitle(isEditing ? "Edit Task" : "New Task")
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
            .sheet(isPresented: $showReminderPicker) {
                ReminderPickerSheet(selectedDate: $reminderDate)
            }
            .sheet(isPresented: $showReschedulePicker) {
                rescheduleSheet
            }
        }
        .presentationDetents([.medium])
        .task { isTitleFocused = true }
    }

    private var reminderRow: some View {
        HStack {
            if let date = reminderDate {
                Button(action: showReminder) {
                    Label {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    } icon: {
                        Image(systemName: "bell.fill")
                    }
                    .font(YATATheme.captionFont)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Remove Reminder", systemImage: "xmark.circle.fill", action: removeReminder)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add Reminder", systemImage: "bell", action: showReminder)
            }
        }
        .padding(.horizontal, 4)
    }

    private var rescheduleRow: some View {
        HStack {
            Button(action: { showReschedulePicker = true }) {
                Label {
                    Text(rescheduleDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(YATATheme.captionFont)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var rescheduleSheet: some View {
        NavigationStack {
            DatePicker(
                "Reschedule to",
                selection: $rescheduleDate,
                in: Calendar.current.startOfDay(for: .now)...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showReschedulePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onReschedule?(rescheduleDate)
                        showReschedulePicker = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, reminderDate)
        dismiss()
    }

    private func removeReminder() {
        reminderDate = nil
    }

    private func showReminder() {
        showReminderPicker = true
    }
}
