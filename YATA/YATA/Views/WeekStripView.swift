import SwiftUI

struct WeekStripView: View {
    let weekDates: [Date]
    let selectedDate: Date
    let taskCounts: [Date: [Priority: Int]]
    let onSelectDate: (Date) -> Void

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
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let dayStart = calendar.startOfDay(for: date)
        let counts = taskCounts[dayStart] ?? [:]

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
                        DotRingView(
                            highCount: counts[.high] ?? 0,
                            mediumCount: counts[.medium] ?? 0,
                            lowCount: counts[.low] ?? 0
                        )
                        .opacity(isSelected ? 0.9 : (isToday ? 0.6 : 0.4))
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
