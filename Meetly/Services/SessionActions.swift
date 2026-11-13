import Foundation
import SwiftData

enum SessionActions {
    static func archive(_ session: MeetingSession, context: ModelContext) {
        session.isArchived = true
        session.archivedAt = .now
        session.pinnedAt = nil
        save(context)
    }

    static func togglePin(_ session: MeetingSession, context: ModelContext) {
        session.pinnedAt = session.isPinned ? nil : .now
        save(context)
    }

    static func unarchive(_ session: MeetingSession, context: ModelContext) {
        session.isArchived = false
        session.archivedAt = nil
        save(context)
    }

    static func delete(_ session: MeetingSession, context: ModelContext) {
        context.delete(session)
        save(context)
    }

    static func deleteAllArchived(_ sessions: [MeetingSession], context: ModelContext) {
        for session in sessions {
            context.delete(session)
        }
        save(context)
    }

    private static func save(_ context: ModelContext) {
        try? context.save()
    }
}

extension MeetingSession {
    func formattedDuration() -> String? {
        guard let duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d min %02d sec", minutes, seconds)
    }
}
