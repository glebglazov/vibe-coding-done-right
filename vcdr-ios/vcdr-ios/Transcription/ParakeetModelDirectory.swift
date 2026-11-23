import FluidAudio
import Foundation

/// Which Parakeet build the app runs, and where its CoreML files live: VCDR's
/// own model root rather than the cache directory every FluidAudio entry point
/// defaults to. The provider, the background warmer and the launch prediction
/// all ask through here, so none of them can look for the model where the
/// others are not putting it.
nonisolated enum ParakeetModelDirectory {
    static let version: AsrModelVersion = .ultra

    /// The FluidAudio repository `version` downloads from.
    static let repo: Repo = .parakeetUltra

    /// The SDK's own folder name is kept, because `AsrModels` recomputes the
    /// repo path from the parent directory and would not find files under any
    /// other name.
    static func url(in root: URL = TranscriptionModelRoot.url) -> URL {
        TranscriptionModelRoot.directory(
            named: AsrModels.defaultCacheDirectory(for: version).lastPathComponent,
            in: root
        )
    }

    /// Whether every file the model loads from is on disk in `root`.
    static func holdsModel(in root: URL = TranscriptionModelRoot.url) -> Bool {
        AsrModels.modelsExist(at: url(in: root), version: version)
    }
}
