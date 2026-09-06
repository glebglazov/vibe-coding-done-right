import Foundation

/// A published set of Whisper weights, and which Transcription Model runs it.
/// The raw value is the variant string WhisperKit identifies a checkpoint by,
/// which is per-model data rather than a pattern: argmax names the turbo
/// checkpoint `openai_whisper-large-v3-v20240930_626MB`, and the
/// `_turbo_632MB` beside it is a compute-config variant of that same
/// checkpoint rather than another one.
///
/// Only multilingual checkpoints are here. The English-only `.en` siblings
/// cannot accept a Language Hint at all, and a family whose members disagree
/// about a setting is not one family (`docs/adr/0020`) — so offering one would
/// mean showing a Whisper the family's own Language Hint does not reach.
enum WhisperCheckpoint: String, CaseIterable, Sendable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case largeV3 = "openai_whisper-large-v3"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"

    /// The Transcription Model this checkpoint is, as the rest of the app names
    /// it. Two vocabularies meet here and nowhere else: argmax's for a file on
    /// Hugging Face, the app's for something a person chooses.
    var model: TranscriptionModel {
        switch self {
        case .tiny: .whisperTiny
        case .base: .whisperBase
        case .small: .whisperSmall
        case .medium: .whisperMedium
        case .largeV3: .whisperLargeV3
        case .largeV3Turbo: .whisperLargeV3Turbo
        }
    }
}
