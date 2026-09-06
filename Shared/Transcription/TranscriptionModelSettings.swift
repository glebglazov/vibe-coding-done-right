import Foundation

/// What one Transcription Model has been told. Only a model that declares the
/// matching Capability reads a field here: a model with no Capabilities carries
/// these values and nothing ever sends them anywhere.
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

    /// What a model that has never been configured is told: a language it has
    /// to detect for itself, and nothing else.
    static let `default` = TranscriptionModelSettings()
}

/// Every Transcription Model's own settings, keyed by model. The keying is what
/// makes them the model's own: switching the Default away and back, or removing
/// the model and installing it again, finds the same answers waiting.
struct TranscriptionModelSettingsStore: Codable, Equatable, Sendable {

    /// Keyed by the model's raw value rather than by the model, so settings
    /// belonging to a model this build does not know are carried through a
    /// downgrade instead of failing the decode for every model.
    private var byModel: [String: TranscriptionModelSettings] = [:]

    init() {}

    subscript(model: TranscriptionModel) -> TranscriptionModelSettings {
        get { byModel[model.rawValue] ?? .default }
        set { byModel[model.rawValue] = newValue }
    }
}
