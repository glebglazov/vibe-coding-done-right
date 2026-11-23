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

    /// The directory inside the root that holds this model's files, having
    /// moved `existingDownload` into it when that is still where the SDK left
    /// it. Someone who already ran an older build keeps the 461 MB they paid
    /// for rather than fetching it a second time.
    ///
    /// Resolving is the whole migration: the filesystem is what remembers it
    /// happened, so a second launch finds nothing at the older path and says
    /// nothing, and a device that never downloaded falls through to a normal
    /// download into the returned directory.
    ///
    /// The SDK's own folder name is kept, because `AsrModels` recomputes the
    /// repo path from the parent directory and would not find files under any
    /// other name. When an SDK update renames that folder, `folderName` is the
    /// new name, and the older download is moved under it so the SDK fetches
    /// only the files the new release adds.
    static func adopting(
        _ existingDownload: URL,
        renamedTo folderName: String? = nil,
        into root: URL = url
    ) -> URL {
        let fm = FileManager.default
        let destination = directory(named: folderName ?? existingDownload.lastPathComponent, in: root)

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Logger.transcription.error("Could not create the model root at \(root.path): \(error)")
            return destination
        }

        // The root is authoritative once it holds the model. An older build run
        // since the move would have refilled the SDK's cache, and that copy is
        // left where it is rather than deleted to tidy up after a downgrade.
        guard !fm.fileExists(atPath: destination.path),
              fm.fileExists(atPath: existingDownload.path)
        else { return destination }

        do {
            try fm.moveItem(at: existingDownload, to: destination)
            Logger.transcription.info("Moved \(existingDownload.path) into the model root at \(destination.path)")
        } catch {
            // A download into the returned directory is the fallback, which is
            // what a device without the older copy does anyway.
            Logger.transcription.error("Could not move \(existingDownload.path) to \(destination.path): \(error)")
        }
        return destination
    }

    /// The directory inside the root that holds the model whose files an SDK
    /// names `folderName`. The Library asks this to size and delete an install
    /// without running the migration `adopting(_:renamedTo:into:)` performs.
    static func directory(named folderName: String, in root: URL = url) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }
}
