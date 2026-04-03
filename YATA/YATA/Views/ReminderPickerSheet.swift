import SwiftUI

struct ReminderPickerSheet: View {
    @Binding var selectedDate: Date?
    @Binding var isPresented: Bool

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
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
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

    private func cancel() {
        isPresented = false
    }

    private func save() {
        selectedDate = pickerDate
        isPresented = false
    }
}
