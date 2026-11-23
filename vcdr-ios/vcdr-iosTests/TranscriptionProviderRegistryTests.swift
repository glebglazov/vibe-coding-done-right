import Foundation
import Testing
@testable import vcdr_ios

@Suite("The iOS Transcription Model Library")
struct TranscriptionProviderRegistryTests {

    /// The path a person takes when they try a Whisper, dislike it, and go back
    /// to Parakeet between two recordings. Going back must return the provider
    /// that already holds its compiled CoreML models, not a fresh one that pays
    /// the cold load again — and it must happen without the app restarting,
    /// which is what asking the registry twice in one process stands for.
    @Test("switching models between recordings keeps each model loaded")
    func switchingBackReturnsTheSameProvider() {
        let registry = TranscriptionProviderRegistry()

        let parakeet = registry.provider(for: .parakeetUltra)
        let whisper = registry.provider(for: .whisperLargeV3Turbo)
        let parakeetAgain = registry.provider(for: .parakeetUltra)

        #expect(parakeet.model == .parakeetUltra)
        #expect(whisper.model == .whisperLargeV3Turbo)
        #expect(parakeetAgain as AnyObject === parakeet as AnyObject)
    }

    @Test("every model iOS offers has a provider that runs it")
    func everyOfferedModelHasItsProvider() {
        let registry = TranscriptionProviderRegistry()

        for model in TranscriptionProviderRegistry.offeredModels {
            #expect(registry.provider(for: model).model == model)
        }
    }
}
