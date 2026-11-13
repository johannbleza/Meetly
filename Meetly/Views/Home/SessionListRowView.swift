import SwiftData
import SwiftUI

/// What can be done to a meeting from the list: the row's hover buttons and its right-click menu.
struct MeetingItemActions {
    let onOpen: () -> Void
    /// Nil while a meeting is recording, or where continuing doesn't apply.
    var onContinue: (() -> Void)?
    /// Nil where pinning doesn't apply (archived meetings).
    var onTogglePin: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    let onExport: () -> Void
    /// Nil while the meeting is being recorded.
    var onDelete: (() -> Void)?
}

extension MeetingItemActions {
    /// The usual actions for a meeting, disabling the ones that don't apply while it's recording or archived.
    @MainActor
    static func standard(
        for session: MeetingSession,
        sessionManager: SessionManager,
        context: ModelContext,
        onOpen: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> MeetingItemActions {
        let isInUse = sessionManager.isInUse(session)
        let isArchived = session.isArchivedValue
        return MeetingItemActions(
            onOpen: onOpen,
            onContinue: !isArchived && sessionManager.state == .idle ? {
                onOpen()
                Task { await sessionManager.continueMeeting(session) }
            } : nil,
            onTogglePin: isArchived ? nil : {
                SessionActions.togglePin(session, context: context)
            },
            onArchive: isArchived || isInUse ? nil : {
                SessionActions.archive(session, context: context)
            },
            onUnarchive: isArchived ? {
                SessionActions.unarchive(session, context: context)
            } : nil,
            onExport: {
                MeetingMarkdownExporter.export(session)
            },
            onDelete: isInUse ? nil : onDelete
        )
    }
}

/// One meeting in the list layout: title, duration and Ask AI chips, and the start time,
/// which hover swaps for quick actions.
struct SessionListRowView: View {
    let session: MeetingSession
    let actions: MeetingItemActions

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .accessibilityLabel("Pinned")
            }

            Text(session.displayTitle)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            MeetingChips(session: session)

            Spacer(minLength: 12)

            ZStack(alignment: .trailing) {
                Text(MeetingTimeText.short(session.startedAt))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .opacity(isHovered ? 0 : 1)
                MeetingQuickActions(session: session, actions: actions)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? AppTheme.bgHover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: actions.onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .meetingContextMenu(session: session, actions: actions)
    }
}

/// One meeting in the grid layout: a card with the title, time, chips and a summary excerpt.
struct MeetingCardView: View {
    let session: MeetingSession
    let actions: MeetingItemActions

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 6) {
                Text(session.startedAt.formatted(.dateTime.month(.abbreviated).day()))
                Text("·")
                Text(MeetingTimeText.short(session.startedAt))
            }
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.textSecondary)

            Text(session.summary?.summaryText ?? "No summary yet.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(3)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                MeetingChips(session: session)
                Spacer(minLength: 0)
                MeetingQuickActions(session: session, actions: actions)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? AppTheme.bgHover : AppTheme.bgSidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: actions.onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .meetingContextMenu(session: session, actions: actions)
    }
}

/// Start times as "7:45pm".
enum MeetingTimeText {
    static func short(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
            .lowercased()
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

/// The duration chip and, when Ask AI was used, the question count chip.
struct MeetingChips: View {
    let session: MeetingSession

    var body: some View {
        HStack(spacing: 6) {
            if let duration = session.duration {
                MeetingChip(
                    text: MeetingMarkdownExporter.clockDuration(duration),
                    foreground: AppTheme.textSecondary,
                    background: AppTheme.bgInput
                )
            }
            // Questions are saved as question/answer pairs.
            let questionCount = (session.qaMessages?.count ?? 0) / 2
            if questionCount > 0 {
                MeetingChip(
                    text: questionCount == 1 ? "1 question" : "\(questionCount) questions",
                    foreground: AppTheme.accent,
                    background: AppTheme.accentSoft
                )
            }
        }
    }
}

struct MeetingChip: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize()
    }
}

private struct MeetingQuickActions: View {
    let session: MeetingSession
    let actions: MeetingItemActions

    var body: some View {
        HStack(spacing: 2) {
            if let onContinue = actions.onContinue {
                button(icon: "play.fill", help: "Continue Meeting", action: onContinue)
            }
            if let onTogglePin = actions.onTogglePin {
                button(
                    icon: session.isPinned ? "pin.slash" : "pin",
                    help: session.isPinned ? "Unpin" : "Pin",
                    action: onTogglePin
                )
            }
            if let onUnarchive = actions.onUnarchive {
                button(icon: "arrow.uturn.backward", help: "Unarchive", action: onUnarchive)
            }
            if let onArchive = actions.onArchive {
                button(icon: "archivebox", help: "Archive", action: onArchive)
            }
            // Delete stays in the right-click menu only.
        }
    }

    private func button(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.bgInput))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    func meetingContextMenu(session: MeetingSession, actions: MeetingItemActions) -> some View {
        contextMenu {
            Button("Open", action: actions.onOpen)
            if let onContinue = actions.onContinue {
                Button("Continue Meeting", action: onContinue)
            }
            Divider()
            if let onTogglePin = actions.onTogglePin {
                Button(session.isPinned ? "Unpin" : "Pin", action: onTogglePin)
            }
            Button("Export as Markdown…", action: actions.onExport)
            if let onUnarchive = actions.onUnarchive {
                Button("Unarchive", action: onUnarchive)
            }
            if let onArchive = actions.onArchive {
                Button("Archive", action: onArchive)
            }
            if let onDelete = actions.onDelete {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

#Preview {
    let session = MeetingSession(title: "Weekly Sync")
    let actions = MeetingItemActions(onOpen: {}, onContinue: {}, onTogglePin: {}, onArchive: {}, onExport: {}, onDelete: {})
    return VStack {
        SessionListRowView(session: session, actions: actions)
        MeetingCardView(session: session, actions: actions)
            .frame(width: 280)
    }
    .padding()
    .frame(width: 640)
}

/// One search result: the meeting's title and date, then a preview of where the query matched
/// in the transcript (or summary), with the match highlighted.
struct SearchResultRowView: View {
    let session: MeetingSession
    let query: String
    var isSelected = false
    let actions: MeetingItemActions

    @State private var isHovered = false

    var body: some View {
        let match = SearchSnippet.firstMatch(in: session, query: query)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .accessibilityLabel("Pinned")
                }
                HighlightedText(text: session.displayTitle, query: query, font: .system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let count = match?.count, count > 0 {
                    MeetingChip(
                        text: count == 1 ? "1 match" : "\(count) matches",
                        foreground: AppTheme.accent,
                        background: AppTheme.accentSoft
                    )
                }
                if session.isArchivedValue {
                    MeetingChip(text: "Archived", foreground: AppTheme.textSecondary, background: AppTheme.bgInput)
                }
                Spacer(minLength: 12)
                Text(dateLine)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize()
            }

            if let match {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(match.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize()
                    HighlightedText(
                        text: match.excerpt,
                        query: query,
                        font: .system(size: 13),
                        foreground: AppTheme.textSecondary
                    )
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected || isHovered ? AppTheme.bgHover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: actions.onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .meetingContextMenu(session: session, actions: actions)
    }

    /// "Today · 7:45pm", "Nov 3 · 7:45pm", or with the year when it isn't this year.
    private var dateLine: String {
        let date = session.startedAt
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return "\(day) · \(MeetingTimeText.short(date))"
    }
}

/// Finds the first place a search query appears in a meeting and cuts a short excerpt around it.
enum SearchSnippet {
    struct Match {
        /// "You", "Other" or "Summary".
        let label: String
        let excerpt: String
        /// Occurrences across the transcript and summary.
        let count: Int
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    /// Characters kept before the match so it lands near the start of the preview.
    private static let leadingContext = 48

    static func firstMatch(in session: MeetingSession, query: String) -> Match? {
        let needle = KeywordHighlighter.normalizedQuery(query)
        guard !needle.isEmpty else { return nil }

        let segments = session.segments.sorted { $0.timestamp < $1.timestamp }
        var summaryParts: [String] = []
        if let summary = session.summary {
            summaryParts.append(summary.summaryText)
            summaryParts.append(contentsOf: summary.keyPoints)
            summaryParts.append(contentsOf: summary.actionItems.map(\.text))
        }

        var count = 0
        var first: (label: String, text: String, range: Range<String.Index>)?
        for segment in segments {
            let occurrences = KeywordHighlighter.occurrenceCount(in: segment.text, query: needle)
            guard occurrences > 0 else { continue }
            count += occurrences
            if first == nil, let range = segment.text.range(of: needle, options: options) {
                first = (segment.speaker.label, segment.text, range)
            }
        }
        for part in summaryParts {
            let occurrences = KeywordHighlighter.occurrenceCount(in: part, query: needle)
            guard occurrences > 0 else { continue }
            count += occurrences
            if first == nil, let range = part.range(of: needle, options: options) {
                first = ("Summary", part, range)
            }
        }

        guard let first else { return nil }
        return Match(label: first.label, excerpt: excerpt(first.text, around: first.range), count: count)
    }

    /// The text from a word boundary shortly before the match, with an ellipsis if it was cut.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let flattened = { (s: Substring) in
            s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let start = text.index(range.lowerBound, offsetBy: -leadingContext, limitedBy: text.startIndex) ?? text.startIndex
        guard start > text.startIndex else { return flattened(text[...]) }
        // Start at the next word so the preview doesn't open mid-word.
        let wordStart = text[start..<range.lowerBound].firstIndex(where: \.isWhitespace)
            .map { text.index(after: $0) } ?? start
        return "…" + flattened(text[wordStart...])
    }
}
