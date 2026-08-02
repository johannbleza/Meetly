import Foundation
import SwiftData

@MainActor
@Observable
final class ActionItemsController {
    private(set) var isGenerating = false
    private(set) var errorMessage: String?

    let session: MeetingSession
    private let modelContext: ModelContext
    private let aiService = AIService()

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

    var canGenerate: Bool {
        hasSourceContent && isAvailable && !isGenerating
    }

    var hasSourceContent: Bool {
        MeetingContextBuilder.hasContent(for: session)
    }

    func generate(replacingExisting: Bool = true) async {
        guard canGenerate else { return }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        guard aiService.isAvailable else {
            errorMessage = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings to generate action items."
            return
        }

        guard hasSourceContent else {
            errorMessage = "This meeting has no transcript or summary to extract action items from."
            return
        }

        do {
            let context = MeetingContextBuilder.context(for: session)
            let items = try await aiService.generateActionItems(from: context)

            guard let summary = session.summary else { return }

            if replacingExisting {
                for item in summary.actionItems {
                    modelContext.delete(item)
                }
                summary.actionItems.removeAll()
            }

            let startOrder = replacingExisting ? 0 : summary.actionItems.count
            for (offset, text) in items.enumerated() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let item = ActionItem(text: trimmed, sortOrder: startOrder + offset, summary: summary)
                summary.actionItems.append(item)
                modelContext.insert(item)
            }

            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCompletion(for item: ActionItem) {
        item.isCompleted.toggle()
        try? modelContext.save()
    }
}
