import Foundation
import OSLog

/// Where Meetly keeps its data now that it runs outside the App Sandbox. The generic default
/// locations would be shared with every other unsandboxed app.
nonisolated enum AppStoragePaths {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Meetly", directoryHint: .isDirectory)
    }

    static var store: URL {
        root.appending(path: storeFileName)
    }

    static var whisperModels: URL {
        root.appending(path: "WhisperModels", directoryHint: .isDirectory)
    }

    fileprivate static let storeFileName = "default.store"
}

/// Copies data from the old App Sandbox container on the first unsandboxed launch. The container
/// is left untouched as a backup. Must run before anything opens the store or reads settings.
nonisolated enum LegacyContainerMigration {
    private static let migratedDefaultsKey = "didMigrateSandboxDefaults"
    private static let logger = Logger(subsystem: "johann.Meetly", category: "LegacyContainerMigration")

    static func runIfNeeded() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let libraryFolder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(bundleIdentifier)/Data/Library", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: libraryFolder.path) else { return }

        let legacySupport = libraryFolder.appending(path: "Application Support", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: AppStoragePaths.root, withIntermediateDirectories: true)
            try migrateStore(from: legacySupport)
            try migrateWhisperModels(from: legacySupport)
        } catch {
            logger.error("Could not copy sandbox data: \(error.localizedDescription, privacy: .public)")
        }
        migrateDefaults(from: libraryFolder.appending(path: "Preferences/\(bundleIdentifier).plist"))
    }

    private static func migrateStore(from legacySupport: URL) throws {
        let fileManager = FileManager.default
        let name = AppStoragePaths.storeFileName
        let legacyStore = legacySupport.appending(path: name)
        guard !fileManager.fileExists(atPath: AppStoragePaths.store.path),
              fileManager.fileExists(atPath: legacyStore.path) else { return }

        // Copy everything into a staging folder first, then move the main store file last,
        // so an interrupted copy can't leave a store missing its write-ahead log.
        let staging = AppStoragePaths.root.appending(path: ".migrating-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let companions = ["\(name)-wal", "\(name)-shm", ".default_SUPPORT"]
        for item in companions + [name] {
            let source = legacySupport.appending(path: item)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: staging.appending(path: item))
            }
        }
        for item in companions + [name] {
            let staged = staging.appending(path: item)
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.moveItem(at: staged, to: AppStoragePaths.root.appending(path: item))
            }
        }
    }

    private static func migrateWhisperModels(from legacySupport: URL) throws {
        let fileManager = FileManager.default
        let legacyModels = legacySupport.appending(path: "WhisperModels", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: AppStoragePaths.whisperModels.path),
              fileManager.fileExists(atPath: legacyModels.path) else { return }

        let staging = AppStoragePaths.root.appending(path: ".migrating-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: legacyModels, to: staging)
        try fileManager.moveItem(at: staging, to: AppStoragePaths.whisperModels)
    }

    private static func migrateDefaults(from legacyPreferences: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedDefaultsKey),
              let legacyValues = NSDictionary(contentsOf: legacyPreferences) as? [String: Any] else { return }

        for (key, value) in legacyValues where !key.hasPrefix("gemini") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }

        // Installed Whisper models are remembered by absolute path.
        let foldersKey = WhisperModelStore.installedFoldersKey
        if let folders = defaults.dictionary(forKey: foldersKey) as? [String: String] {
            // Matches on the container's tail because the home prefix can be spelled differently.
            let legacyTail = "/Data/Library/Application Support/WhisperModels"
            let newFolder = AppStoragePaths.whisperModels.path
            defaults.set(
                folders.mapValues { path in
                    guard let range = path.range(of: legacyTail) else { return path }
                    return newFolder + path[range.upperBound...]
                },
                forKey: foldersKey
            )
        }
        defaults.set(true, forKey: migratedDefaultsKey)
    }
}
