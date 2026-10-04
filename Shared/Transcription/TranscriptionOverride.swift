import Foundation

/// A Mode's departure from a Transcription Model Family's own settings, setting
/// by setting. Every field is optional, and nil means the Mode never said
/// anything about it — so the family's own value is what runs, and editing that
/// value on the Transcription screen reaches this Mode.
///
/// A whole-blob snapshot was rejected for exactly that reason (`docs/adr/0016`):
/// it would quietly cut the global settings screen off from the Modes that
/// matter most.
struct TranscriptionSettingsPatch: Codable, Equatable, Sendable {
    var languageHint: LanguageHint?
    var freeTextPrompt: String?

    /// `settings` with everything this Mode set for itself replacing what the
    /// family's own settings say. The result is what the provider is told.
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
        // The Dictionary is one list for every Mode.
        case .spellingHints: false
        }
    }

    /// Gives `capability` back to the family's own settings.
    mutating func clear(_ capability: TranscriptionModelCapability) {
        switch capability {
        case .languageHint: languageHint = nil
        case .freeTextPrompt: freeTextPrompt = nil
        case .spellingHints: break
        }
    }

    /// Records what an edit changed, and only that. A settings screen hands
    /// back whole settings, so the difference from the ones it was showing is
    /// exactly the setting the person just touched — everything else stays
    /// unset and keeps following the family.
    mutating func record(_ edited: TranscriptionModelSettings, replacing shown: TranscriptionModelSettings) {
        if edited.languageHint != shown.languageHint { languageHint = edited.languageHint }
        if edited.freeTextPrompt != shown.freeTextPrompt { freeTextPrompt = edited.freeTextPrompt }
    }
}

/// A Mode's Transcription Override: the Transcription Model it pins instead of
/// the Default, and what it has told each Transcription Model Family.
///
/// The patches are kept per family and outside the pin, so nothing a Mode has
/// configured is attached to the selection (`docs/adr/0016`): pointing a Mode at
/// another model — or back at the Default — and returning finds this Mode's own
/// answers waiting, and pointing it at another member of the same family finds
/// the same ones.
struct TranscriptionOverride: Codable, Equatable, Sendable {

    /// The model this Mode transcribes with, or nil when the Mode leaves
    /// transcription alone and takes the Default.
    var model: TranscriptionModel?

    /// Keyed by the family's raw value rather than by the family, so a patch
    /// belonging to a family this build does not know is carried through a
    /// downgrade instead of failing the decode for every Mode.
    private var patches: [String: TranscriptionSettingsPatch] = [:]

    /// What a Mode that has never touched transcription carries.
    static let none = TranscriptionOverride()

    /// Written out, because this type reads and writes both sides of its own
    /// Codable and Swift then synthesizes nothing.
    private enum CodingKeys: String, CodingKey {
        case model
        case patches
    }

    subscript(family: TranscriptionModelFamily) -> TranscriptionSettingsPatch {
        get { patches[family.rawValue] ?? TranscriptionSettingsPatch() }
        set { patches[family.rawValue] = newValue }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(TranscriptionModel.self, forKey: .model)
        patches = TranscriptionModelFamily.adoptingKeysBeforeFamilies(
            in: try container.decodeIfPresent([String: TranscriptionSettingsPatch].self, forKey: .patches) ?? [:]
        )
    }

    /// Written out rather than synthesized, for the same reason
    /// `TranscriptionModelSettingsStore` writes its own: iOS also makes this
    /// type `RawRepresentable` so `@AppStorage` can hold a Prompt Mode's
    /// Override, and Swift would otherwise satisfy `Encodable` with
    /// `RawRepresentable`'s default — which encodes `rawValue`, which encodes
    /// this, forever.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(patches, forKey: .patches)
    }
}

/// What one recording run transcribes with: which Transcription Model, and what
/// its family is told. Resolved from the Mode and the app's transcription
/// settings at each use and never stored, so an edit to either reaches the next
/// recording rather than the next launch.
struct EffectiveTranscription: Equatable, Sendable {
    let model: TranscriptionModel
    let settings: TranscriptionModelSettings
}
