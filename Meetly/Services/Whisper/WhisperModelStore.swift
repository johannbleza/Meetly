import Foundation
import Observation
import WhisperKit

enum WhisperModel: String, CaseIterable, Identifiable {
    case base
    case small
    case largeV3 = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .base: "Base: fastest, lowest accuracy"
        case .small: "Small: balanced"
        case .largeV3: "Large v3: most accurate, heaviest"
        }
    }
}

enum WhisperModelError: LocalizedError {
    case notInstalled(WhisperModel)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The selected Whisper model isn't downloaded yet. Download it in Settings."
        }
    }
}

/// Owns Whisper model files. Installing happens from Settings ahead of time, because the
/// download and first Core ML load can take minutes and must not delay a meeting's start.
@MainActor
@Observable
final class WhisperModelStore {
    enum InstallPhase: Equatable {
        case downloading(fraction: Double)
        case optimizing
    }

    static let shared = WhisperModelStore()

    private(set) var installingModel: WhisperModel?
    private(set) var installPhase: InstallPhase?
    private(set) var lastError: String?
    private var installedFolders: [String: String]
    private var installTask: Task<Void, Never>?

    nonisolated static let installedFoldersKey = "whisperInstalledModelFolders"

    private init() {
        installedFolders = UserDefaults.standard.dictionary(forKey: Self.installedFoldersKey) as? [String: String] ?? [:]
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        installedFolder(for: model) != nil
    }

    func install(_ model: WhisperModel) {
        guard installTask == nil else { return }
        lastError = nil
        installingModel = model
        installPhase = .downloading(fraction: 0)

        installTask = Task {
            do {
                let folder = try await downloadModel(model)
                try Task.checkCancellation()
                installPhase = .optimizing
                // The first load compiles the model for this Mac and caches the tokenizer,
                // so later meetings start quickly and work offline.
                let runtime = try await WhisperRuntime(modelFolder: folder, tokenizerFolder: Self.storageFolder)
                await runtime.unload()
                setInstalledFolder(folder.path, for: model)
            } catch is CancellationError {
                // Cancelled by the user; nothing to report.
            } catch {
                lastError = error.localizedDescription
            }
            installingModel = nil
            installPhase = nil
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func remove(_ model: WhisperModel) {
        guard let folder = installedFolder(for: model) else { return }
        try? FileManager.default.removeItem(at: folder)
        setInstalledFolder(nil, for: model)
    }

    /// Loads an installed model. Never downloads, so it can't stall a meeting's start.
    func loadRuntime(for model: WhisperModel) async throws -> WhisperRuntime {
        guard let folder = installedFolder(for: model) else {
            throw WhisperModelError.notInstalled(model)
        }
        return try await WhisperRuntime(modelFolder: folder, tokenizerFolder: Self.storageFolder)
    }

    private func downloadModel(_ model: WhisperModel) async throws -> URL {
        try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: Self.storageFolder,
            progressCallback: { @Sendable [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.installPhase != nil, self.installPhase != .optimizing else { return }
                    self.installPhase = .downloading(fraction: fraction)
                }
            }
        )
    }

    private func installedFolder(for model: WhisperModel) -> URL? {
        guard let path = installedFolders[model.rawValue],
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func setInstalledFolder(_ path: String?, for model: WhisperModel) {
        installedFolders[model.rawValue] = path
        UserDefaults.standard.set(installedFolders, forKey: Self.installedFoldersKey)
    }

    private static var storageFolder: URL {
        AppStoragePaths.whisperModels
    }
}
