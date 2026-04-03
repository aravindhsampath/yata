import SwiftUI

struct ReminderPickerSheet: View {
    @Binding var selectedDate: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var pickerDate = Date.now

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                DatePicker(
                    "Date",
                    selection: $pickerDate,
                    in: Date.now...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)

                DatePicker(
                    "Time",
                    selection: $pickerDate,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(height: 100)

                Spacer()
            }
            .padding()
            .navigationTitle("Set Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        selectedDate = pickerDate
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            if let selectedDate {
                pickerDate = selectedDate
            }
        }
    }
}
