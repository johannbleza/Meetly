import SwiftUI

/// Meetings under one heading of the activity list: "Pinned", "Today", "Yesterday" or a date.
struct MeetingActivityGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [MeetingSession]

    /// Meetings by start day, newest first; with `separatingPinned`, pinned meetings get their own group on top.
    static func groups(for sessions: [MeetingSession], separatingPinned: Bool = false) -> [MeetingActivityGroup] {
        var groups: [MeetingActivityGroup] = []
        var rest = sessions

        if separatingPinned {
            let pinned = sessions
                .filter(\.isPinned)
                .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            if !pinned.isEmpty {
                groups.append(MeetingActivityGroup(id: "pinned", title: "Pinned", sessions: pinned))
            }
            rest = sessions.filter { !$0.isPinned }
        }

        let calendar = Calendar.current
        let byDay = Dictionary(grouping: rest) { calendar.startOfDay(for: $0.startedAt) }
        for day in byDay.keys.sorted(by: >) {
            let daySessions = (byDay[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            groups.append(MeetingActivityGroup(id: day.ISO8601Format(), title: dayTitle(day), sessions: daySessions))
        }
        return groups
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

/// The empty or no-results message under an activity list.
struct MeetingActivityEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
