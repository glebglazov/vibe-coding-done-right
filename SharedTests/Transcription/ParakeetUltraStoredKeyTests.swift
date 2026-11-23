import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Parakeet Ultra replaced Parakeet v3, and everything an older build stored
/// under v3's key must name Ultra after the update, with nothing lost. One
/// source tree compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@Suite("Parakeet v3's stored key")
struct ParakeetUltraStoredKeyTests {

    @Test("a stored parakeet-v3 reads as Parakeet Ultra, and Ultra writes its own key")
    func v3KeyReadsAsUltra() {
        #expect(TranscriptionModel(rawValue: "parakeet-v3") == .parakeetUltra)
        #expect(TranscriptionModel.parakeetUltra.rawValue == "parakeet-ultra")
        #expect(TranscriptionModel(rawValue: "canary") == nil)
        for model in TranscriptionModel.allCases {
            #expect(TranscriptionModel(rawValue: model.rawValue) == model)
        }
    }

    @Test("a Mode that pinned parakeet-v3 pins Parakeet Ultra, and saves it as parakeet-ultra")
    func modePinOnV3ReadsAsUltra() throws {
        let stored = Data(#"{"model":"parakeet-v3","patches":{"parakeet":{"freeTextPrompt":"VCDR"}}}"#.utf8)

        let override = try JSONDecoder().decode(TranscriptionOverride.self, from: stored)

        #expect(override.model == .parakeetUltra)
        #expect(override[.parakeet].freeTextPrompt == "VCDR")
        let saved = try String(data: JSONEncoder().encode(override), encoding: .utf8)!
        #expect(saved.contains(#""model":"parakeet-ultra""#))
        #expect(!saved.contains("parakeet-v3"))
    }

    @Test("family settings stored under parakeet-v3 before families are Parakeet's")
    func familySettingsKeyedByV3AreParakeets() throws {
        let stored = Data(#"{"byModel":{"parakeet-v3":{"languageHint":"detect","freeTextPrompt":"VCDR, Parakeet"}}}"#.utf8)

        let store = try JSONDecoder().decode(TranscriptionModelSettingsStore.self, from: stored)

        #expect(store[.parakeet].freeTextPrompt == "VCDR, Parakeet")
        let saved = try String(data: JSONEncoder().encode(store), encoding: .utf8)!
        #expect(!saved.contains("parakeet-v3"))
    }
}
