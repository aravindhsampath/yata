import SwiftUI

enum AddEditMode: Identifiable {
    case add
    case edit(TodoItem)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let item): item.id.uuidString
        }
    }
}

struct AddEditSheet: View {
    let mode: AddEditMode
    let onSave: (String, Date?) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var reminderDate: Date?
    @State private var showReminderPicker = false
    @FocusState private var isTitleFocused: Bool

    init(
        mode: AddEditMode,
        onSave: @escaping (String, Date?) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete

        switch mode {
        case .add:
            _title = State(initialValue: "")
            _reminderDate = State(initialValue: nil)
        case .edit(let item):
            _title = State(initialValue: item.title)
            _reminderDate = State(initialValue: item.reminderDate)
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
                ReminderPickerSheet(
                    selectedDate: $reminderDate,
                    isPresented: $showReminderPicker
                )
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
