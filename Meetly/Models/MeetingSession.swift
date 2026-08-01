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
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    var segments: [TranscriptSegment]
    @Relationship(deleteRule: .cascade, inverse: \MeetingSummary.session)
    var summary: MeetingSummary?

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
        return endedAt.timeIntervalSince(startedAt)
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var isArchivedValue: Bool {
        isArchived ?? false
    }
}
