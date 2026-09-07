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

    /// The Transcription Model every recording runs unless something names
    /// another. Parakeet until someone chooses otherwise: it is the model iOS
    /// shipped with, and the one already on disk for everyone upgrading.
    static var defaultModel: TranscriptionModel {
        UserDefaults.standard.string(forKey: defaultModelKey)
            .flatMap(TranscriptionModel.init(rawValue:))
            ?? .parakeetV3
    }

    /// Where the Transcription Model a Prompt Mode names for itself lives —
    /// one key per mode, because iOS has three fixed modes rather than modes a
    /// person makes. Read through `@AppStorage` by the mode's own screen.
    static func modeModelKey(for mode: AIPromptMode) -> String {
        "transcription_mode_model_\(mode.rawValue)"
    }

    /// The Transcription Model `mode` records with instead of the Default, or
    /// nil when the mode names nothing and follows the Default.
    static func modelNamed(by mode: AIPromptMode) -> TranscriptionModel? {
        UserDefaults.standard.string(forKey: modeModelKey(for: mode))
            .flatMap(TranscriptionModel.init(rawValue:))
    }

    /// Every Prompt Mode that names `model`. The Library asks before it removes
    /// one: a model a mode records with is refused rather than deleted out from
    /// under that mode.
    static func promptModesNaming(_ model: TranscriptionModel) -> [AIPromptMode] {
        AIPromptMode.allCases.filter { modelNamed(by: $0) == model }
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
