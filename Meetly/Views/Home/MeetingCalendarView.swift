import SwiftUI

/// A month grid of meetings: the month title with back / Today / forward, weekday headings,
/// and each day's meetings as a dot, title and time. Days with more than fit show "N more".
struct MeetingCalendarView: View {
    let sessions: [MeetingSession]
    /// Any day in the month being shown.
    @Binding var month: Date
    let actions: (MeetingSession) -> MeetingItemActions
    var isRecording: (MeetingSession) -> Bool = { _ in false }

    private static let maxVisibleEvents = 3
    private static let rowHeight: CGFloat = 118

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 0) {
                weekdayHeader
                grid
            }
            .background(AppTheme.bgSidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text(month.formatted(.dateTime.month(.wide))).fontWeight(.bold)
                + Text(" ") + Text(month.formatted(.dateTime.year())).fontWeight(.regular))
                .font(.system(size: 24))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            HStack(spacing: 0) {
                CalendarNavButton(systemImage: "chevron.left", help: "Previous month") { shiftMonth(by: -1) }
                Rectangle().fill(AppTheme.border).frame(width: 1, height: 18)
                Button("Today") { month = .now }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .disabled(calendar.isDate(month, equalTo: .now, toGranularity: .month))
                Rectangle().fill(AppTheme.border).frame(width: 1, height: 18)
                CalendarNavButton(systemImage: "chevron.right", help: "Next month") { shiftMonth(by: 1) }
            }
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.bgSidebar))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private func shiftMonth(by value: Int) {
        if let shifted = calendar.date(byAdding: .month, value: value, to: month) {
            month = shifted
        }
    }

    // MARK: Grid

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols.indices, id: \.self) { index in
                Text(weekdaySymbols[index])
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) { AppDivider(axis: .horizontal) }
    }

    /// Short weekday names starting on the user's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var grid: some View {
        let days = gridDays
        let byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        return VStack(spacing: 0) {
            ForEach(weeks.indices, id: \.self) { weekIndex in
                HStack(spacing: 0) {
                    ForEach(weeks[weekIndex], id: \.self) { day in
                        CalendarDayCell(
                            day: day,
                            isInMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                            isToday: calendar.isDateInToday(day),
                            isWeekend: calendar.isDateInWeekend(day),
                            sessions: (byDay[day] ?? []).sorted { $0.startedAt < $1.startedAt },
                            maxVisibleEvents: Self.maxVisibleEvents,
                            actions: actions,
                            isRecording: isRecording
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.rowHeight)
                        .overlay(alignment: .trailing) {
                            if day != weeks[weekIndex].last {
                                AppDivider()
                            }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if weekIndex != weeks.count - 1 {
                        AppDivider(axis: .horizontal)
                    }
                }
            }
        }
    }

    /// Whole weeks covering the month, starting on the user's first weekday.
    private var gridDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: interval.start)?.count else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let cellCount = Int((Double(leading + dayCount) / 7).rounded(.up)) * 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: interval.start) else { return [] }
        return (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

private struct CalendarDayCell: View {
    let day: Date
    let isInMonth: Bool
    let isToday: Bool
    let isWeekend: Bool
    let sessions: [MeetingSession]
    let maxVisibleEvents: Int
    let actions: (MeetingSession) -> MeetingItemActions
    let isRecording: (MeetingSession) -> Bool

    @State private var isShowingAll = false

    /// Room for "N more" when the day overflows.
    private var visibleSessions: ArraySlice<MeetingSession> {
        sessions.count > maxVisibleEvents ? sessions.prefix(maxVisibleEvents - 1) : sessions.prefix(maxVisibleEvents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                dayNumber
            }
            .padding(.bottom, 2)

            ForEach(visibleSessions) { session in
                CalendarEventRow(session: session, actions: actions(session), isRecording: isRecording(session))
            }

            if sessions.count > visibleSessions.count {
                Button("\(sessions.count - visibleSessions.count) more") {
                    isShowingAll = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.leading, 6)
                .popover(isPresented: $isShowingAll, arrowEdge: .trailing) {
                    dayPopover
                }
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isWeekend ? AppTheme.bgPrimary : AppTheme.bgSidebar)
    }

    private var dayNumber: some View {
        let isFirstOfMonth = Calendar.current.component(.day, from: day) == 1
        let label = isFirstOfMonth
            ? day.formatted(.dateTime.month(.abbreviated).day())
            : day.formatted(.dateTime.day())

        return Text(label)
            .font(.system(size: 13, weight: isToday ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.white : (isInMonth ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.6)))
            .padding(.horizontal, isToday ? 6 : 4)
            .frame(minWidth: 24, minHeight: 24)
            .background {
                if isToday {
                    Capsule().fill(Color.red)
                }
            }
    }

    private var dayPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.bottom, 4)
            ForEach(sessions) { session in
                CalendarEventRow(
                    session: session,
                    actions: actions(session),
                    isRecording: isRecording(session),
                    showsHoverDetails: false
                )
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// One meeting in a day cell: a colored dot, the title and the start time.
/// Resting the pointer on it shows a details card.
private struct CalendarEventRow: View {
    let session: MeetingSession
    let actions: MeetingItemActions
    let isRecording: Bool
    /// Off inside the "N more" popover, where a second popover would stack on the first.
    var showsHoverDetails = true

    @State private var isHovered = false
    @State private var isShowingDetails = false
    @State private var hoverTask: Task<Void, Never>?

    /// How long the pointer rests before the details appear, so sweeping across the grid doesn't flash cards.
    private static let hoverDelay: Duration = .milliseconds(450)

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isRecording ? AppTheme.danger : AppTheme.accent)
                .frame(width: 6, height: 6)
            Text(session.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text(MeetingTimeText.short(session.startedAt))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? AppTheme.accentSoft : .clear)
        )
        .contentShape(Rectangle())
        .onHover(perform: hoverChanged)
        .onTapGesture {
            hideDetails()
            actions.onOpen()
        }
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            CalendarEventDetails(session: session, isRecording: isRecording)
        }
        .onDisappear(perform: hideDetails)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayTitle), \(session.startedAt.formatted(date: .omitted, time: .shortened))")
        .accessibilityAddTraits(.isButton)
        .meetingContextMenu(session: session, actions: actions)
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovered = hovering
        hoverTask?.cancel()
        guard showsHoverDetails else { return }
        if hovering {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled else { return }
                isShowingDetails = true
            }
        } else {
            isShowingDetails = false
        }
    }

    private func hideDetails() {
        hoverTask?.cancel()
        isShowingDetails = false
    }
}

/// The hover card for a calendar meeting: title, when, chips, summary and action items.
private struct CalendarEventDetails: View {
    let session: MeetingSession
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isRecording ? AppTheme.danger : AppTheme.accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(whenText)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                    if isRecording {
                        Text("Recording now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.danger)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            MeetingChips(session: session)

            if let summary = session.summary?.summaryText, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No summary yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if let items = session.summary?.actionItems, !items.isEmpty {
                let open = items.filter { !$0.isCompleted }.count
                Label(
                    open == 0
                        ? "All \(items.count) action items done"
                        : "\(open) of \(items.count) action items open",
                    systemImage: "checklist"
                )
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
            }

            Text("Click to open")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    /// "Friday, Nov 13 · 7:45 – 7:49 PM", or just the start while there's no end.
    private var whenText: String {
        let day = session.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard let endedAt = session.endedAt else {
            return "\(day) · \(session.startedAt.formatted(date: .omitted, time: .shortened))"
        }
        let range = (session.startedAt..<max(endedAt, session.startedAt))
            .formatted(.interval.hour().minute())
        return "\(day) · \(range)"
    }
}

private struct CalendarNavButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
