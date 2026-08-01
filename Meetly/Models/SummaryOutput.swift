import Foundation

struct SummaryOutput: Codable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
}
