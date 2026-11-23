import Foundation
import OSLog

/// The one directory every Transcription Model's files live under, so a Library
/// screen can list, size and delete them without asking each SDK where it chose
/// to put its own.
///
/// Nonisolated on purpose: the providers that resolve a model directory are
/// actors initializing behind launch, and the explicit `nonisolated` overrides
/// the target-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.
nonisolated enum TranscriptionModelRoot {

    /// Beside the Local Store, in the app's own storage — the app group on iOS,
    /// Application Support on macOS. Lowercase, as every container folder this
    /// app names is (see `docs/adr/0013`).
    static var url: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent("models", isDirectory: true)
    }

    /// Deletes the folders of the models `model` replaced, once `model` has
    /// loaded. This is the one delete the app does without a remove command:
    /// the person never chose the replaced model, so nothing else would ever
    /// give its space back. A folder already gone is the end state, so a second
    /// call does nothing. Only names directly inside `root` are touched.
    static func removeDownloads(replacedBy model: TranscriptionModel, in root: URL = url) {
        for folderName in folderNamesReplaced(by: model) {
            let folder = directory(named: folderName, in: root)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                try TranscriptionModelFiles(directory: folder).remove()
                Logger.transcription.info("Removed \(folder.path), which \(model.displayName) replaced")
            } catch {
                Logger.transcription.error("Could not remove \(folder.path): \(error)")
            }
        }
    }

    /// The folders Parakeet v3 was kept in: `parakeet-tdt-0.6b-v3` from
    /// FluidAudio 0.18, and `parakeet-tdt-0.6b-v3-coreml` from builds on 0.12
    /// that were never run on 0.18.
    private static func folderNamesReplaced(by model: TranscriptionModel) -> [String] {
        switch model {
        case .parakeetUltra: ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v3-coreml"]
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeV3, .whisperLargeV3Turbo: []
        }
    }

    /// The directory inside the root that holds the model whose files an SDK
    /// names `folderName`.
    static func directory(named folderName: String, in root: URL = url) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }
}
