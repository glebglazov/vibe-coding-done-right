import Foundation
import Testing
import WhisperKit
@testable import vcdr_mac

@Suite("Transcription Model Settings")
@MainActor
struct TranscriptionModelSettingsTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("A model is told what only it accepts, and Whisper's hint reaches the call that transcribes")
    func settingsReachTheModelThatRuns() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        // A hint the recording does not match is the setting that costs most,
        // and the one a person can genuinely choose — so it is what is driven
        // through here.
        env.settings.transcriptionSettings.modelSettings[.whisperLargeV3Turbo] =
            TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "VCDR, Parakeet")
        env.settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo

        await record(with: env)

        #expect(await env.alternateProvider.receivedSettings?.languageHint == .russian)
        #expect(await env.alternateProvider.receivedSettings?.freeTextPrompt == "VCDR, Parakeet")

        // Parakeet accepts neither, and is told neither: the settings a run
        // carries are the running model's own, not the ones last configured.
        env.settings.transcriptionSettings.defaultModel = .parakeetV3
        await record(with: env)
        #expect(await env.mockProvider.receivedSettings == TranscriptionModelSettings.default)
    }

    @Test("Detect passes no language, and a named hint passes its code")
    func detectPassesNoLanguage() {
        let promptTokens = [11, 22, 33]

        let detecting = WhisperProvider.decodingOptions(for: .default) { _ in promptTokens }
        #expect(detecting.language == nil)
        // Nil alone is not enough: WhisperKit fills an unset language slot
        // with English unless it is asked to detect.
        #expect(detecting.detectLanguage)
        #expect(detecting.promptTokens == nil)

        let hinted = WhisperProvider.decodingOptions(
            for: TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "Parakeet")
        ) { _ in promptTokens }
        #expect(hinted.language == "ru")
        #expect(hinted.detectLanguage == false)
        #expect(hinted.promptTokens == promptTokens)
        #expect(hinted.usePrefillPrompt)
    }

    @Test("A model declares the kinds it accepts, and one that accepts nothing says why")
    func capabilitiesAreDeclaredPerModel() {
        #expect(TranscriptionModel.whisperLargeV3Turbo.capabilities == .kinds([.languageHint, .freeTextPrompt]))

        guard case .nothing(let reason) = TranscriptionModel.parakeetV3.capabilities else {
            Issue.record("Parakeet declares no Capability, so it owes an explanation")
            return
        }
        #expect(reason.contains("no language"))
    }

    @Test("The prompt is capped at what the model's window can hold")
    func promptIsCapped() {
        let limit = TranscriptionModelSettings.freeTextPromptCharacterLimit
        var settings = TranscriptionModelSettings()
        settings.freeTextPrompt = String(repeating: "a", count: limit * 2)

        #expect(settings.freeTextPrompt.count == limit)
    }

    @Test("A model's settings survive the Default moving away and back, a relaunch, and a removal")
    func settingsStayWithTheirModel() async {
        let suiteName = "vcdr.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        let configured = TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "Parakeet")

        settings.transcriptionSettings.modelSettings[.whisperLargeV3Turbo] = configured
        settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo
        settings.transcriptionSettings.defaultModel = .parakeetV3

        // Parakeet being the Default gives it nothing of Whisper's.
        #expect(settings.transcriptionSettings.modelSettings[.parakeetV3] == .default)

        let root = FileManager.default.temporaryDirectory.appending(path: "vcdr-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let whisper = MockTranscriptionProvider(
            model: .whisperLargeV3Turbo,
            installedDirectory: root.appending(path: "whisper")
        )
        try! FileManager.default.createDirectory(at: whisper.installedDirectory, withIntermediateDirectories: true)
        let library = TranscriptionLibrary(
            models: [.whisperLargeV3Turbo],
            provider: { _ in whisper },
            settings: settings
        )
        #expect(await library.remove(.whisperLargeV3Turbo) == nil)

        let relaunched = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        #expect(relaunched.transcriptionSettings.modelSettings[.whisperLargeV3Turbo] == configured)
    }

    private func record(with env: CaptureSessionTestEnvironment) async {
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForRest())
        _ = await env.session.waitForNextIdle(timeout: .seconds(2))
    }
}
