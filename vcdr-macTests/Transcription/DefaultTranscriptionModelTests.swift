import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

@Suite("Default Transcription Model")
@MainActor
struct DefaultTranscriptionModelTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Parakeet is the Default until someone picks otherwise, and the pick survives a launch")
    func choicePersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        #expect(settings.transcriptionSettings.defaultModel == .parakeetV3)

        settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo

        let relaunched = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        #expect(relaunched.transcriptionSettings.defaultModel == .whisperLargeV3Turbo)
    }

    @Test("A model that has been loaded stays loaded: switching away and back finds the same provider")
    func providersStayResident() {
        let registry = TranscriptionProviderRegistry()

        let parakeet = registry.provider(for: .parakeetV3)
        let whisper = registry.provider(for: .whisperLargeV3Turbo)
        #expect(whisper.model == .whisperLargeV3Turbo)

        #expect(registry.provider(for: .parakeetV3) as AnyObject === parakeet as AnyObject)
        #expect(registry.provider(for: .whisperLargeV3Turbo) as AnyObject === whisper as AnyObject)
    }

    @Test("The chosen Default is what transcribes the next recording")
    func chosenModelTranscribes() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "from parakeet"),
            alternateProvider: MockTranscriptionProvider(
                model: .whisperLargeV3Turbo,
                result: "from whisper"
            )
        )
        defer { env.cleanup() }

        #expect(await record(with: env)?.finalText == "from parakeet ")

        env.settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo

        #expect(await record(with: env)?.finalText == "from whisper ")
    }

    private func record(with env: CaptureSessionTestEnvironment) async -> CaptureSession.Outcome? {
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForRest())
        return await env.session.waitForNextIdle(timeout: .seconds(2))
    }
}
