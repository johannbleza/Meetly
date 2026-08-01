import Foundation
import SwiftData

enum Speaker: String, Codable, CaseIterable {
    case me = "me"
    case other = "other"

    var label: String {
        switch self {
        case .me: "You"
        case .other: "Other"
        }
    }
}

@Model
final class TranscriptSegment {
    var text: String
    var timestamp: Date
    var speakerRaw: String
    var isFinal: Bool
    var session: MeetingSession?

    var speaker: Speaker {
        get { Speaker(rawValue: speakerRaw) ?? .other }
        set { speakerRaw = newValue.rawValue }
    }

    init(
        text: String,
        timestamp: Date = .now,
        speaker: Speaker,
        isFinal: Bool = true,
        session: MeetingSession? = nil
    ) {
        self.text = text
        self.timestamp = timestamp
        self.speakerRaw = speaker.rawValue
        self.isFinal = isFinal
        self.session = session
    }
}

struct LiveTranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let speaker: Speaker
    let isFinal: Bool

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = .now,
        speaker: Speaker,
        isFinal: Bool
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
        self.isFinal = isFinal
    }

    init(from segment: TranscriptSegment) {
        self.id = UUID()
        self.text = segment.text
        self.timestamp = segment.timestamp
        self.speaker = segment.speaker
        self.isFinal = segment.isFinal
    }
}
