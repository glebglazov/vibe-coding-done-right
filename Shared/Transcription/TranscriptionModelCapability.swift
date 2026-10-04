import Foundation

/// A kind of thing a Transcription Model Family can be told. Typed by kind
/// rather than as a list of string options, because two families differ in
/// *what* they accept and not only in the values: Parakeet has no language
/// token and no text prompt at all, which no value of a closed string list can
/// express (`docs/adr/0017`).
enum TranscriptionModelCapability: String, Codable, Sendable, Hashable {
    case languageHint
    case freeTextPrompt
    /// The Dictionary's Spelling Hints. Unlike the other kinds it is not a
    /// setting: one Dictionary serves every family and every Mode, so there is
    /// nothing to type here and nothing a Mode can override (`docs/adr/0025`).
    case spellingHints
}

/// What a Transcription Model Family declares it can be told — or, for a family
/// that accepts nothing, why. The two travel as one answer so a screen built
/// from the declaration can never render no controls and no explanation.
enum TranscriptionModelCapabilities: Equatable, Sendable {
    /// The kinds this family accepts, in the order its settings screen renders
    /// them.
    case kinds([TranscriptionModelCapability])
    /// This family accepts nothing, and this is what its screen says instead.
    case nothing(because: String)
}

extension TranscriptionModelFamily {
    /// What this family accepts, declared once for every member: a family whose
    /// members disagree about a Capability is two families. A settings screen is
    /// built from this, so a new family with an unfamiliar hint means a new
    /// Capability kind rather than a wider string list.
    var capabilities: TranscriptionModelCapabilities {
        switch self {
        case .parakeet:
            .nothing(because: """
                Parakeet accepts no settings. One vocabulary spans Latin and \
                Cyrillic and the language of each word is decided as it is \
                emitted, so there is no language to set — and the model takes \
                no text prompt. It does not use your Dictionary yet.
                """)
        case .whisper:
            .kinds([.languageHint, .freeTextPrompt, .spellingHints])
        }
    }
}
