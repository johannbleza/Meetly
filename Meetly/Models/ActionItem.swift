import Foundation
import SwiftData

@Model
final class ActionItem {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var sortOrder: Int
    var summary: MeetingSummary?

    init(
        text: String,
        sortOrder: Int = 0,
        isCompleted: Bool = false,
        summary: MeetingSummary? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
        self.summary = summary
    }
}
