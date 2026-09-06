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
    /// Where the per-model settings live. Read through `@AppStorage` by the
    /// Transcription section, which is the only writer.
    static let modelSettingsKey = "transcription_model_settings"

    /// The Transcription Model every recording runs. iOS transcribes through a
    /// sliding window over the offline Parakeet encoder, and WhisperKit's live
    /// path is chunked re-decoding with different confirmation semantics, so
    /// the iOS Library holds this one model until that streaming work is done
    /// (`docs/adr/0018`) — one model is one answer, and there is nothing to
    /// store until there is a second.
    static let defaultModel = TranscriptionModel.parakeetV3
}

/// Lets `@AppStorage` hold the whole model-keyed store, so the Transcription
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
