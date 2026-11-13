import Foundation
import SwiftData

/// Lowercased searchable text for every meeting, built off the main thread.
///
/// Sidebar search used to read every meeting's transcript, summary and action items on the
/// main actor for each keystroke. The index reads them once in a background `ModelContext`,
/// so filtering is just a string lookup per meeting.
nonisolated enum MeetingSearchIndex {
    typealias Index = [UUID: String]

    static func build(container: ModelContainer) async -> Index {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let sessions = try? context.fetch(FetchDescriptor<MeetingSession>()) else {
                return [:]
            }
            var index = Index(minimumCapacity: sessions.count)
            for session in sessions {
                if Task.isCancelled { return [:] }
                index[session.id] = searchableText(for: session)
            }
            return index
        }.value
    }

    static func normalizedNeedle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Matches the title live (titles can change while the index is being used) and
    /// everything else through the index. Without an index yet, only titles match.
    static func matches(_ session: MeetingSession, needle: String, index: Index?) -> Bool {
        guard !needle.isEmpty else { return true }
        if session.displayTitle.lowercased().contains(needle) { return true }
        return index?[session.id]?.contains(needle) ?? false
    }

    private static func searchableText(for session: MeetingSession) -> String {
        var parts: [String] = []
        if let summary = session.summary {
            parts.append(summary.summaryText)
            parts.append(contentsOf: summary.keyPoints)
            parts.append(contentsOf: summary.actionItems.map(\.text))
        }
        parts.append(contentsOf: session.segments.map(\.text))
        // A separator that can't appear in a typed query keeps matches from spanning parts.
        return parts.joined(separator: "\u{0}").lowercased()
    }
}

/// Debounced sidebar search state with a background-built index.
@MainActor
@Observable
final class SidebarSearchModel {
    var text = "" {
        didSet { scheduleApply() }
    }

    /// Lowercased query the list filters by; trails `text` by a short debounce.
    private(set) var needle = ""
    private(set) var index: MeetingSearchIndex.Index?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    var isSearching: Bool { !needle.isEmpty }

    func matches(_ session: MeetingSession) -> Bool {
        MeetingSearchIndex.matches(session, needle: needle, index: index)
    }

    func attach(to container: ModelContainer) {
        self.container = container
    }

    /// Meetings were added, removed or changed. Rebuilds the index if a search is showing;
    /// otherwise the next search rebuilds it anyway.
    func meetingsChanged() {
        if isSearching { rebuildIndex() }
    }

    private func scheduleApply() {
        debounceTask?.cancel()
        let newNeedle = MeetingSearchIndex.normalizedNeedle(text)
        // Clearing the field should feel instant, and frees the index.
        if newNeedle.isEmpty {
            needle = ""
            indexTask?.cancel()
            index = nil
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let startsSearch = self.needle.isEmpty
            self.needle = newNeedle
            // Rebuild per search, not per keystroke, so newly saved summaries and
            // transcripts are found without holding stale text for long.
            if startsSearch { self.rebuildIndex() }
        }
    }

    private func rebuildIndex() {
        guard let container else { return }
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let built = await MeetingSearchIndex.build(container: container)
            guard !Task.isCancelled else { return }
            self?.index = built
        }
    }
}
