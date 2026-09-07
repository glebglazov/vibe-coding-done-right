import Foundation
import Testing
@testable import vcdr_ios

@Suite("iOS transcription settings storage", .serialized)
struct TranscriptionSettingsTests {

    /// Drives the whole path a relaunch takes: what a family was told is
    /// written as `@AppStorage` writes it, read back the way the next launch
    /// reads it, and — the part that matters — is nowhere the keyboard
    /// extension or another device could see it.
    @Test("what a family is told survives a relaunch and stays on this device")
    func modelSettingsAreThisDevicesOwn() {
        let key = TranscriptionSettings.modelSettingsKey
        let standard = UserDefaults.standard
        let shared = SharedConstants.sharedDefaults
        let original = standard.string(forKey: key)
        defer {
            if let original {
                standard.set(original, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }

        var store = TranscriptionModelSettingsStore()
        store[.whisper] = TranscriptionModelSettings(
            languageHint: .russian,
            freeTextPrompt: "VCDR, Parakeet"
        )
        standard.set(store.rawValue, forKey: key)

        let reloaded = TranscriptionModelSettingsStore(rawValue: standard.string(forKey: key) ?? "")
        #expect(reloaded?[.whisper] == store[.whisper])
        #expect(reloaded?[.parakeet] == .default)
        #expect(shared.object(forKey: key) == nil)
    }

    /// The Default a person picks is read afresh for every recording, so the
    /// next one runs the model they just chose — no relaunch, and nothing
    /// carried over from the model that ran the last one.
    @Test("the Default Transcription Model is this device's, and takes effect on the next recording")
    func defaultModelIsChosenPerDevice() {
        let key = TranscriptionSettings.defaultModelKey
        let standard = UserDefaults.standard
        let original = standard.string(forKey: key)
        defer {
            if let original {
                standard.set(original, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }

        standard.removeObject(forKey: key)
        #expect(TranscriptionSettings.defaultModel == .parakeetV3)

        standard.set(TranscriptionModel.whisperLargeV3Turbo.rawValue, forKey: key)
        #expect(TranscriptionSettings.defaultModel == .whisperLargeV3Turbo)
        #expect(SharedConstants.sharedDefaults.object(forKey: key) == nil)
    }

    /// The whole resolution a recording runs through: the mode's own model, the
    /// one setting it adjusted, everything it left alone still following the
    /// family — and the adjusted one handed back.
    @Test("a mode records with the model it names, adjusts one setting and inherits the rest")
    func aModeRecordsWithItsOwnModel() {
        let standard = UserDefaults.standard
        let keys = [
            TranscriptionSettings.defaultModelKey,
            TranscriptionSettings.modelSettingsKey,
            TranscriptionSettings.modeOverrideKey(for: .dictation),
            TranscriptionSettings.modeOverrideKey(for: .assistant)
        ]
        let originals = keys.map { ($0, standard.string(forKey: $0)) }
        defer {
            for (key, value) in originals {
                if let value {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }
        for key in keys { standard.removeObject(forKey: key) }

        var store = TranscriptionModelSettingsStore()
        store[.whisper] = TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "VCDR")
        standard.set(store.rawValue, forKey: TranscriptionSettings.modelSettingsKey)

        var override = TranscriptionOverride.none
        override.model = .whisperSmall
        override[.whisper].languageHint = .english
        standard.set(override.rawValue, forKey: TranscriptionSettings.modeOverrideKey(for: .dictation))

        let dictation = TranscriptionSettings.effectiveTranscription(for: .dictation)
        #expect(dictation.model == .whisperSmall)
        #expect(dictation.settings.languageHint == .english)
        #expect(dictation.settings.freeTextPrompt == "VCDR")

        // A mode that names nothing takes the Default and the Default family's
        // own settings, untouched by the mode next to it.
        let assistant = TranscriptionSettings.effectiveTranscription(for: .assistant)
        #expect(assistant.model == .parakeetV3)
        #expect(assistant.settings == .default)

        override[.whisper].clear(.languageHint)
        standard.set(override.rawValue, forKey: TranscriptionSettings.modeOverrideKey(for: .dictation))
        #expect(TranscriptionSettings.effectiveTranscription(for: .dictation).settings.languageHint == .russian)
    }
}
