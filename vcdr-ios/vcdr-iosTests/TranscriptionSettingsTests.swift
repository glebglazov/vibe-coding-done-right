import Foundation
import Testing
import WhisperKit
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
    @Test("a mode records with the model it pins, adjusts one setting and inherits the rest")
    func aModeRecordsWithItsOwnModel() {
        let standard = UserDefaults.standard
        let keys = [
            TranscriptionSettings.defaultModelKey,
            TranscriptionSettings.modelSettingsKey,
            TranscriptionSettings.modeOverrideKey(for: .dictation),
            TranscriptionSettings.modeOverrideKey(for: .verbatim)
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

        // A mode that pins nothing takes the Default and the Default family's
        // own settings, untouched by the mode next to it.
        let aiOff = TranscriptionSettings.effectiveTranscription(for: .verbatim)
        #expect(aiOff.model == .parakeetV3)
        #expect(aiOff.settings == .default)

        override[.whisper].clear(.languageHint)
        standard.set(override.rawValue, forKey: TranscriptionSettings.modeOverrideKey(for: .dictation))
        #expect(TranscriptionSettings.effectiveTranscription(for: .dictation).settings.languageHint == .russian)
    }

    /// What a family is told, as WhisperKit's decoder receives it — plus the
    /// one thing nobody chose: this phone reads a decode segment by segment,
    /// and a segment carries Whisper's control markers unless the options say
    /// otherwise. Asserted here so a later edit to the options cannot drop it
    /// and put the markers back in a person's transcript.
    @Test("the decoder is asked to leave Whisper's markers out, whatever the family was told")
    func decodingOptionsSkipSpecialTokens() {
        let detecting = WhisperProvider.decodingOptions(for: .default, spellingHints: .none, tokenizedBy: nil)
        #expect(detecting.skipSpecialTokens)
        // Nil alone is not enough: WhisperKit fills an unset language slot
        // with English unless it is asked to detect.
        #expect(detecting.language == nil)
        #expect(detecting.detectLanguage)
        #expect(detecting.promptTokens == nil)

        let hinted = WhisperProvider.decodingOptions(
            for: TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "Parakeet"),
            spellingHints: .none,
            tokenizedBy: nil
        )
        #expect(hinted.skipSpecialTokens)
        #expect(hinted.language == "ru")
        #expect(hinted.detectLanguage == false)
        #expect(hinted.usePrefillPrompt)
    }

    @Test("Whisper's prompt tokens are the typed prompt followed by the Dictionary's Spelling Hints")
    func promptCarriesSpellingHints() {
        let tokenizer = ScalarTokenizer()
        let hints = SpellingHints([Substitution(triggerPhrases: [], replacement: "Gleb Glazov")])

        let typedAndHinted = WhisperProvider.decodingOptions(
            for: TranscriptionModelSettings(freeTextPrompt: "Parakeet"),
            spellingHints: hints,
            tokenizedBy: tokenizer
        )
        #expect(typedAndHinted.promptTokens == tokenizer.encode(text: " Parakeet, Gleb Glazov"))

        // Nothing typed still primes the model, with the hints alone.
        let hintsOnly = WhisperProvider.decodingOptions(for: .default, spellingHints: hints, tokenizedBy: tokenizer)
        #expect(hintsOnly.promptTokens == tokenizer.encode(text: " Gleb Glazov"))
    }
}

/// One token per Unicode scalar, so a test can read back exactly which text
/// was encoded.
private struct ScalarTokenizer: WhisperTokenizer {
    private static let firstSpecialToken = 0x110000

    let specialTokens = SpecialTokens(
        endToken: firstSpecialToken,
        englishToken: firstSpecialToken + 1,
        noSpeechToken: firstSpecialToken + 2,
        noTimestampsToken: firstSpecialToken + 3,
        specialTokenBegin: firstSpecialToken,
        startOfPreviousToken: firstSpecialToken + 4,
        startOfTranscriptToken: firstSpecialToken + 5,
        timeTokenBegin: firstSpecialToken + 6,
        transcribeToken: firstSpecialToken + 7,
        translateToken: firstSpecialToken + 8,
        whitespaceToken: Int(UnicodeScalar(" ").value)
    )
    let allLanguageTokens: Set<Int> = []

    func encode(text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokens: [Int]) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}
