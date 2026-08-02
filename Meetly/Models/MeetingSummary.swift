import Foundation
import SwiftData

@Model
final class MeetingSummary {
    var summaryText: String
    var keyPoints: [String]
    @Relationship(deleteRule: .cascade, inverse: \ActionItem.summary)
    var actionItems: [ActionItem]
    var generatedAt: Date
    var session: MeetingSession?

    init(
        summaryText: String,
        keyPoints: [String] = [],
        actionItems: [ActionItem] = [],
        generatedAt: Date = .now,
        session: MeetingSession? = nil
    ) {
        self.summaryText = summaryText
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.generatedAt = generatedAt
        self.session = session
    }

    var sortedActionItems: [ActionItem] {
        actionItems.sorted { $0.sortOrder < $1.sortOrder }
    }
}
