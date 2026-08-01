import Foundation
import SwiftData

@Model
final class MeetingSummary {
    var summaryText: String
    var keyPoints: [String]
    var actionItems: [String]
    var generatedAt: Date
    var session: MeetingSession?

    init(
        summaryText: String,
        keyPoints: [String] = [],
        actionItems: [String] = [],
        generatedAt: Date = .now,
        session: MeetingSession? = nil
    ) {
        self.summaryText = summaryText
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.generatedAt = generatedAt
        self.session = session
    }
}
