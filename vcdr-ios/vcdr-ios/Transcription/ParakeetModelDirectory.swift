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
    static func url() -> URL {
        TranscriptionModelRoot.adopting(AsrModels.defaultCacheDirectory(for: .v3))
    }
}
