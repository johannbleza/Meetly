//
//  MeetlyApp.swift
//  Meetly
//

import SwiftData
import SwiftUI

@main
struct MeetlyApp: App {
    @State private var sessionManager = SessionManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MeetingSession.self,
            TranscriptSegment.self,
            MeetingSummary.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Recover from failed lightweight migrations (e.g. new non-optional fields on existing stores).
            Self.removePersistentStore(at: configuration.url)
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    private static func removePersistentStore(at url: URL) {
        let fileManager = FileManager.default
        let relatedURLs = [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal"),
        ]
        for storeURL in relatedURLs where fileManager.fileExists(atPath: storeURL.path) {
            try? fileManager.removeItem(at: storeURL)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(sessionManager: sessionManager)
                .preferredColorScheme(.dark)
                .onAppear {
                    GeminiKeyStore.migrateFromDotEnvIfNeeded()
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 720)
    }
}
