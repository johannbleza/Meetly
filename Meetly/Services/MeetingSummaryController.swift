import Foundation
import SwiftData

@MainActor
@Observable
final class MeetingSummaryController {
    private(set) var isGenerating = false
    private(set) var errorMessage: String?

    let session: MeetingSession
    private let modelContext: ModelContext
    private let aiService = AIService()
    private var task: Task<Void, Never>?

    init(session: MeetingSession, modelContext: ModelContext) {
        self.session = session
        self.modelContext = modelContext
    }

    var isAvailable: Bool {
        aiService.isAvailable
    }

    var availabilityMessage: String? {
        aiService.availabilityMessage
    }

    var hasTranscript: Bool {
        !MeetingContextBuilder.transcriptText(for: session)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var canGenerate: Bool {
        hasTranscript && isAvailable && !isGenerating
    }

    /// Starts generating, as a task `cancel()` can stop.
    func start() {
        guard canGenerate, task == nil else { return }
        task = Task {
            await generate()
            task = nil
        }
    }

    /// Stops generating. Whatever was there before is left as it was.
    func cancel() {
        task?.cancel()
    }

    func generate() async {
        guard canGenerate else { return }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        guard aiService.isAvailable else {
            errorMessage = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings to generate a summary."
            return
        }

        let transcript = MeetingContextBuilder.transcriptText(for: session)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "This meeting has no transcript to summarize."
            return
        }

        do {
            let output = try await aiService.generateSummary(from: transcript)
            guard !Task.isCancelled else { return }
            apply(output)
            try modelContext.save()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ output: SummaryOutput) {
        let summary: MeetingSummary
        if let existing = session.summary {
            for item in existing.actionItems {
                modelContext.delete(item)
            }
            existing.actionItems.removeAll()
            existing.summaryText = output.summary
            existing.keyPoints = output.keyPoints
            existing.generatedAt = .now
            summary = existing
        } else {
            summary = MeetingSummary(
                summaryText: output.summary,
                keyPoints: output.keyPoints,
                session: session
            )
            session.summary = summary
            modelContext.insert(summary)
        }

        summary.actionItems = output.actionItems.enumerated().compactMap { index, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let item = ActionItem(text: trimmed, sortOrder: index, summary: summary)
            modelContext.insert(item)
            return item
        }

        session.title = output.title
    }
}
