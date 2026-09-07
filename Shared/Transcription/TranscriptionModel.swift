import Foundation

/// Which Transcription Model a provider runs. One vocabulary for both products,
/// so a model is something the app can name rather than only something it can
/// print: Library membership and the model a Mode names both key by this,
/// where a display string would key by wording that is free to change. What a
/// model is told keys by its family instead (`docs/adr/0020`).
///
/// The raw value is that key, and is written down rather than derived from the
/// case name, because it outlives any rename of the case.
enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case parakeetV3 = "parakeet-v3"
    case whisperTiny = "whisper-tiny"
    case whisperBase = "whisper-base"
    case whisperSmall = "whisper-small"
    case whisperMedium = "whisper-medium"
    case whisperLargeV3 = "whisper-large-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    /// The Transcription Model Family this model belongs to, and so what it
    /// can be told and where those answers are kept. Every Whisper shares one
    /// (`docs/adr/0020`).
    var family: TranscriptionModelFamily {
        switch self {
        case .parakeetV3: .parakeet
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeV3, .whisperLargeV3Turbo: .whisper
        }
    }

    /// What every readiness surface — menu bar, settings badge, recording pill —
    /// calls this model.
    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet Multilingual v3"
        case .whisperTiny: "Whisper Tiny"
        case .whisperBase: "Whisper Base"
        case .whisperSmall: "Whisper Small"
        case .whisperMedium: "Whisper Medium"
        case .whisperLargeV3: "Whisper Large v3"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    /// Roughly what this model's files take up once installed, in bytes on
    /// disk. The same measure the Library prints for an install it can see, so
    /// the number weighed before an install and the number shown after it are
    /// two readings of one thing.
    ///
    /// Written down here rather than asked of a backend, because neither
    /// WhisperKit nor FluidAudio publishes a size before a download, and the
    /// one moment the number decides anything is before there is anything to
    /// measure. Keyed by the same enum as `displayName` so a new model cannot
    /// arrive without one. The figures are argmax's published file sizes for
    /// the Whispers and a measured install for Parakeet, rounded to 0.1 GB:
    /// finer than that is precision no decision needs.
    var approximateSizeOnDisk: Int64 {
        switch self {
        case .parakeetV3: 500_000_000
        case .whisperTiny: 100_000_000
        case .whisperBase: 100_000_000
        case .whisperSmall: 500_000_000
        case .whisperMedium: 1_500_000_000
        case .whisperLargeV3: 3_100_000_000
        case .whisperLargeV3Turbo: 600_000_000
        }
    }
}
