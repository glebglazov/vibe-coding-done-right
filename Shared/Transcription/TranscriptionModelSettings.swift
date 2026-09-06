import Foundation

/// What one Transcription Model Family has been told. Only a family that
/// declares the matching Capability reads a field here: a family with no
/// Capabilities carries these values and nothing ever sends them anywhere.
struct TranscriptionModelSettings: Codable, Equatable, Sendable {
    /// Which language the recording is in, or `detect` — the default, which
    /// sends no language at all. Never derived (`docs/adr/0019`).
    var languageHint: LanguageHint

    /// Proper nouns and jargon that bias the model's spelling. A soft hint the
    /// model may ignore, and an over-long one contributes to repeat loops, so
    /// it is capped here as well as shown as capped on screen.
    var freeTextPrompt: String {
        get { Self.capped(storedFreeTextPrompt) }
        set { storedFreeTextPrompt = Self.capped(newValue) }
    }

    /// As many characters as the prompt is allowed to be. Whisper's own window
    /// for it is about 200 tokens, and non-Latin scripts spend tokens faster
    /// than Latin ones, so the cap is set where even the worst case fits.
    static let freeTextPromptCharacterLimit = 400

    private var storedFreeTextPrompt: String

    private enum CodingKeys: String, CodingKey {
        case languageHint
        case storedFreeTextPrompt = "freeTextPrompt"
    }

    private static func capped(_ prompt: String) -> String {
        String(prompt.prefix(freeTextPromptCharacterLimit))
    }

    init(languageHint: LanguageHint = .detect, freeTextPrompt: String = "") {
        self.languageHint = languageHint
        self.storedFreeTextPrompt = Self.capped(freeTextPrompt)
    }

    /// What a family that has never been configured is told: a language it has
    /// to detect for itself, and nothing else.
    static let `default` = TranscriptionModelSettings()
}

/// Every Transcription Model Family's own settings, keyed by family. The
/// keying is what makes them the family's own: switching the Default to
/// another member of the same family, switching it away and back, or removing
/// a model and installing it again, all find the same answers waiting.
struct TranscriptionModelSettingsStore: Codable, Equatable, Sendable {

    /// Keyed by the family's raw value rather than by the family, so settings
    /// belonging to a family this build does not know are carried through a
    /// downgrade instead of failing the decode for every family.
    private var byFamily: [String: TranscriptionModelSettings] = [:]

    init() {}

    subscript(family: TranscriptionModelFamily) -> TranscriptionModelSettings {
        get { byFamily[family.rawValue] ?? .default }
        set { byFamily[family.rawValue] = newValue }
    }

    /// The name an older build wrote this dictionary under, kept as it was:
    /// settings were keyed by model then, and renaming the key here would
    /// strand every one of them.
    private enum CodingKeys: String, CodingKey {
        case byFamily = "byModel"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byFamily = TranscriptionModelFamily.adoptingKeysBeforeFamilies(
            in: try container.decodeIfPresent([String: TranscriptionModelSettings].self, forKey: .byFamily) ?? [:]
        )
    }

    /// Written out rather than synthesized, because iOS also makes this type
    /// `RawRepresentable` so `@AppStorage` can hold it. Both conformances are
    /// in one module there, and Swift then satisfies `Encodable` with
    /// `RawRepresentable`'s default — which encodes `rawValue`, which encodes
    /// the store, forever. A member of its own wins over that default.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byFamily, forKey: .byFamily)
    }
}
