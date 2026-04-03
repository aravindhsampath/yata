import SwiftUI

struct ReminderPickerSheet: View {
    @Binding var selectedDate: Date?
    @Binding var isPresented: Bool

    @State private var pickerDate = Date.now

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "Reminder",
                    selection: $pickerDate,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding()

                Spacer()
            }
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
        .presentationDetents([.medium, .large])
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
