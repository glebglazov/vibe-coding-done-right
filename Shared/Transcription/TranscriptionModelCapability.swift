import Foundation

/// A kind of thing a Transcription Model can be told. Typed by kind rather
/// than as a list of string options, because two models differ in *what* they
/// accept and not only in the values: Parakeet has no language token and no
/// text prompt at all, which no value of a closed string list can express
/// (`docs/adr/0017`).
enum TranscriptionModelCapability: String, Codable, Sendable, Hashable {
    case languageHint
    case freeTextPrompt
}

/// What a Transcription Model declares it can be told — or, for a model that
/// accepts nothing, why. The two travel as one answer so a screen built from
/// the declaration can never render no controls and no explanation.
enum TranscriptionModelCapabilities: Equatable, Sendable {
    /// The kinds this model accepts, in the order its settings screen renders
    /// them.
    case kinds([TranscriptionModelCapability])
    /// This model accepts nothing, and this is what its screen says instead.
    case nothing(because: String)
}

extension TranscriptionModel {
    /// What this model accepts. A model's settings screen is built from this,
    /// so a new model with an unfamiliar hint means a new Capability kind
    /// rather than a wider string list.
    var capabilities: TranscriptionModelCapabilities {
        switch self {
        case .parakeetV3:
            .nothing(because: """
                Parakeet accepts no settings. One vocabulary spans Latin and \
                Cyrillic and the language of each word is decided as it is \
                emitted, so there is no language to set — and the model takes \
                no text prompt.
                """)
        case .whisperLargeV3Turbo:
            .kinds([.languageHint, .freeTextPrompt])
        }
    }
}
