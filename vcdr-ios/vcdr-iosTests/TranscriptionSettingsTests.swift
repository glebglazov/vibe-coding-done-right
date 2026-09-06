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
}
