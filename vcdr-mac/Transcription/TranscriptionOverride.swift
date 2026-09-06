import Foundation

/// A Mode's departure from a Transcription Model's own settings, setting by
/// setting. Every field is optional, and nil means the Mode never said anything
/// about it — so the model's own value is what runs, and editing that value on
/// the Transcription screen reaches this Mode.
///
/// A whole-blob snapshot was rejected for exactly that reason (`docs/adr/0016`):
/// it would quietly cut the global settings screen off from the Modes that
/// matter most.
struct TranscriptionSettingsPatch: Codable, Equatable, Sendable {
    var languageHint: LanguageHint?
    var freeTextPrompt: String?

    /// `settings` with everything this Mode set for itself replacing what the
    /// model's own settings say. The result is what the provider is told.
    func applied(to settings: TranscriptionModelSettings) -> TranscriptionModelSettings {
        var applied = settings
        if let languageHint { applied.languageHint = languageHint }
        if let freeTextPrompt { applied.freeTextPrompt = freeTextPrompt }
        return applied
    }

    /// Whether this Mode set `capability` for itself. The Mode screen shows the
    /// answer beside every control, because a computed value with no
    /// provenance is a value nobody can account for.
    func isSet(_ capability: TranscriptionModelCapability) -> Bool {
        switch capability {
        case .languageHint: languageHint != nil
        case .freeTextPrompt: freeTextPrompt != nil
        }
    }

    /// Gives `capability` back to the model's own settings.
    mutating func clear(_ capability: TranscriptionModelCapability) {
        switch capability {
        case .languageHint: languageHint = nil
        case .freeTextPrompt: freeTextPrompt = nil
        }
    }

    /// Records what an edit changed, and only that. A settings screen hands
    /// back whole settings, so the difference from the ones it was showing is
    /// exactly the setting the person just touched — everything else stays
    /// unset and keeps following the model.
    mutating func record(_ edited: TranscriptionModelSettings, replacing shown: TranscriptionModelSettings) {
        if edited.languageHint != shown.languageHint { languageHint = edited.languageHint }
        if edited.freeTextPrompt != shown.freeTextPrompt { freeTextPrompt = edited.freeTextPrompt }
    }
}

/// A Mode's Transcription Override: the Transcription Model it names instead of
/// the Default, and what it has told each model.
///
/// The patches are kept per model and outside the naming, so nothing a Mode has
/// configured is attached to the selection (`docs/adr/0016`): pointing a Mode at
/// another model — or back at the Default — and returning finds this Mode's own
/// answers waiting.
struct TranscriptionOverride: Codable, Equatable, Sendable {

    /// The model this Mode transcribes with, or nil when the Mode leaves
    /// transcription alone and takes the Default.
    var model: TranscriptionModel?

    /// Keyed by the model's raw value rather than by the model, so a patch
    /// belonging to a model this build does not know is carried through a
    /// downgrade instead of failing the decode for every Mode.
    private var patches: [String: TranscriptionSettingsPatch] = [:]

    /// What a Mode that has never touched transcription carries.
    static let none = TranscriptionOverride()

    subscript(model: TranscriptionModel) -> TranscriptionSettingsPatch {
        get { patches[model.rawValue] ?? TranscriptionSettingsPatch() }
        set { patches[model.rawValue] = newValue }
    }
}

/// What one recording run transcribes with: which Transcription Model, and what
/// that model is told. Resolved from the Mode and the app's transcription
/// settings at each use and never stored, so an edit to either reaches the next
/// recording rather than the next launch.
struct EffectiveTranscription: Equatable, Sendable {
    let model: TranscriptionModel
    let settings: TranscriptionModelSettings
}

extension TranscriptionSettings {

    /// What `mode` transcribes with: its Transcription Override's model under
    /// the Mode's own patch, or the Default Transcription Model and the
    /// Default's own settings when the Mode names nothing.
    ///
    /// The whole resolution — Mode's patch, else the model's own settings, else
    /// the model's defaults — is this one function, because a bug in it shows up
    /// as the wrong model being told the wrong thing, with nothing on screen to
    /// say so.
    func effectiveTranscription(for mode: Mode) -> EffectiveTranscription {
        guard let model = mode.transcriptionOverride.model else {
            return EffectiveTranscription(model: defaultModel, settings: modelSettings[defaultModel])
        }
        return EffectiveTranscription(
            model: model,
            settings: mode.transcriptionOverride[model].applied(to: modelSettings[model])
        )
    }
}
