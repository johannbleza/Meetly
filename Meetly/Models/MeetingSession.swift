import Foundation
import SwiftData

@Model
final class MeetingSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var title: String?
    var isArchived: Bool?
    var archivedAt: Date?
    /// Set while the meeting is pinned to the top of the meetings list.
    var pinnedAt: Date?
    /// Time between recording stretches of a continued meeting, left out of `duration`.
    var continuationGapDuration: TimeInterval?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    var segments: [TranscriptSegment]
    @Relationship(deleteRule: .cascade, inverse: \MeetingSummary.session)
    var summary: MeetingSummary?
    /// Questions asked about this meeting and their answers. Optional so existing stores migrate.
    @Relationship(deleteRule: .cascade, inverse: \QAMessage.session)
    var qaMessages: [QAMessage]?

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        title: String? = nil,
        isArchived: Bool? = false,
        archivedAt: Date? = nil,
        segments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.segments = segments
        self.summary = summary
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt) - (continuationGapDuration ?? 0))
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var isArchivedValue: Bool {
        isArchived ?? false
    }

    var isPinned: Bool {
        pinnedAt != nil
    }

    var sortedQAMessages: [QAMessage] {
        (qaMessages ?? []).sorted { $0.timestamp < $1.timestamp }
    }
}
