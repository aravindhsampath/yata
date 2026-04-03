import SwiftUI

struct WeekStripView: View {
    let weekDates: [Date]
    let selectedDate: Date
    let onSelectDate: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 12) {
            Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(YATATheme.titleFont)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    dayColumn(for: date)
                }
            }
        }
        .padding(.top, 4)
    }

    private func dayColumn(for date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button(action: { onSelectDate(date) }) {
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle()
                                .fill(.tint)
                                .opacity(0.2)
                        } else if isToday {
                            Circle()
                                .strokeBorder(.tint, lineWidth: 1)
                                .opacity(0.4)
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
