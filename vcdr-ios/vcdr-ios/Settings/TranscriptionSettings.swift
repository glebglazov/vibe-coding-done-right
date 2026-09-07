import Foundation

/// The Transcription Model this device runs, and what it has been told.
///
/// Everything here is per-device on purpose. The Library is per-device by
/// nature — different disks, and a different membership on each platform — so a
/// synced Default would name a model this device has not installed and turn the
/// app into a download prompt before it could dictate. `UserDefaults.standard`
/// rather than `sharedDefaults`: the keyboard extension never transcribes, and
/// nothing here crosses to another device.
enum TranscriptionSettings {
    /// Where the per-family settings live. Read through `@AppStorage` by the
    /// Transcription section, which is the only writer.
    static let modelSettingsKey = "transcription_model_settings"

    /// Where the Default Transcription Model lives. Read through `@AppStorage`
    /// by the Transcription section, and read afresh for every recording so a
    /// model chosen between two of them takes effect on the second.
    static let defaultModelKey = "transcription_default_model"

    /// The Transcription Model every recording runs unless something pins
    /// another. Parakeet until someone chooses otherwise: it is the model iOS
    /// shipped with, and the one already on disk for everyone upgrading.
    static var defaultModel: TranscriptionModel {
        UserDefaults.standard.string(forKey: defaultModelKey)
            .flatMap(TranscriptionModel.init(rawValue:))
            ?? .parakeetV3
    }

    /// Where a Prompt Mode's Transcription Override lives — one key per mode,
    /// because iOS has three fixed modes rather than modes a person makes.
    /// Read and written through `@AppStorage` by that mode's own screen.
    static func modeOverrideKey(for mode: AIPromptMode) -> String {
        "transcription_mode_override_\(mode.rawValue)"
    }

    /// What `mode` has said about transcription for itself: the model it
    /// records with instead of the Default, and what it tells each family. A
    /// mode that has never been opened has said nothing.
    static func override(for mode: AIPromptMode) -> TranscriptionOverride {
        UserDefaults.standard.string(forKey: modeOverrideKey(for: mode))
            .flatMap(TranscriptionOverride.init(rawValue:))
            ?? TranscriptionOverride.none
    }

    /// Writes what `mode` has said about transcription for itself. The mode's
    /// own screen writes this through `@AppStorage`; the Library writes it here
    /// when a removal unpins the mode, which is a write no screen is open for.
    static func setOverride(_ override: TranscriptionOverride, for mode: AIPromptMode) {
        UserDefaults.standard.set(override.rawValue, forKey: modeOverrideKey(for: mode))
    }

    /// Every Prompt Mode that pins `model`. The Library discloses them before it
    /// removes one: a model a mode records with is not deleted out from under
    /// that mode without consent (`docs/adr/0024`).
    static func promptModesPinning(_ model: TranscriptionModel) -> [AIPromptMode] {
        AIPromptMode.allCases.filter { override(for: $0).model == model }
    }

    /// What `mode` transcribes with: its Transcription Override's model under
    /// the mode's own patch, or the Default Transcription Model and the
    /// Default's family's own settings when the mode pins nothing.
    ///
    /// The whole resolution — mode's patch, else the family's own settings,
    /// else the family's defaults — is this one function, because a bug in it
    /// shows up as the wrong model being told the wrong thing, with nothing on
    /// screen to say so.
    static func effectiveTranscription(for mode: AIPromptMode) -> EffectiveTranscription {
        let override = override(for: mode)
        guard let model = override.model else {
            return EffectiveTranscription(model: defaultModel, settings: settings(for: defaultModel.family))
        }
        return EffectiveTranscription(
            model: model,
            settings: override[model.family].applied(to: settings(for: model.family))
        )
    }

    /// What `family` has been told on this device. Read at the point a
    /// recording starts rather than held, for the same reason the Default is:
    /// a vocabulary prompt typed in Settings applies to the next recording.
    static func settings(for family: TranscriptionModelFamily) -> TranscriptionModelSettings {
        let store = UserDefaults.standard.string(forKey: modelSettingsKey)
            .flatMap(TranscriptionModelSettingsStore.init(rawValue:))
            ?? TranscriptionModelSettingsStore()
        return store[family]
    }
}

/// Lets `@AppStorage` hold the whole family-keyed store, so the Transcription
/// section reads and writes settings the same way every other iOS setting is
/// read and written. Follows `AIProvider`, which is stored the same way.
extension TranscriptionModelSettingsStore: RawRepresentable {
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let store = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = store
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}

/// Lets `@AppStorage` hold a Prompt Mode's whole Override, so its screen writes
/// the model it pins and its patches the way every other iOS setting is
/// written. Follows `TranscriptionModelSettingsStore` above.
extension TranscriptionOverride: RawRepresentable {
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let override = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = override
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}
