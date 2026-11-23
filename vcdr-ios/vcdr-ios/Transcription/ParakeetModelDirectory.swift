import FluidAudio
import Foundation

/// Where Parakeet's CoreML files live: VCDR's own model root rather than the
/// cache directory every FluidAudio entry point defaults to.
///
/// A function, not a constant, because resolving it is also what moves an older
/// build's download into the root. The provider, the background warmer and the
/// launch prediction all ask through here, so none of them can look for the
/// model where the others are not putting it.
nonisolated enum ParakeetModelDirectory {
    /// The model root's Parakeet folder, after moving an earlier build's
    /// download into it. FluidAudio 0.12 named the folder
    /// `parakeet-tdt-0.6b-v3-coreml`; 0.18 names it `parakeet-tdt-0.6b-v3` and
    /// also needs `JointDecisionv3.mlmodelc` in it. Renaming keeps the 461 MB
    /// already on disk, so the download fetches only what 0.18 adds. The
    /// earlier download is in the model root, or in the SDK's own cache for
    /// builds older than the root. The first move fills the destination, and
    /// the later calls find it full and leave their source alone.
    static func url() -> URL {
        let sdkCache = AsrModels.defaultCacheDirectory(for: .v3)
        let folderName = sdkCache.lastPathComponent
        let earlierFolderName = "parakeet-tdt-0.6b-v3-coreml"
        let earlierDownloads = [
            TranscriptionModelRoot.directory(named: earlierFolderName),
            sdkCache.deletingLastPathComponent().appendingPathComponent(earlierFolderName, isDirectory: true),
            sdkCache,
        ]
        for earlierDownload in earlierDownloads {
            _ = TranscriptionModelRoot.adopting(earlierDownload, renamedTo: folderName)
        }
        return TranscriptionModelRoot.directory(named: folderName)
    }
}
