import Foundation
import Testing
import WhisperKit
@testable import vcdr_mac

@Suite("Transcription Model Settings")
@MainActor
struct TranscriptionModelSettingsTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("A family is told what only it accepts, and Whisper's hint reaches the call that transcribes")
    func settingsReachTheModelThatRuns() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        // A hint the recording does not match is the setting that costs most,
        // and the one a person can genuinely choose — so it is what is driven
        // through here.
        env.settings.transcriptionSettings.modelSettings[.whisper] =
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

    @Test("A family declares the kinds it accepts, and one that accepts nothing says why")
    func capabilitiesAreDeclaredPerFamily() {
        #expect(TranscriptionModelFamily.whisper.capabilities == .kinds([.languageHint, .freeTextPrompt]))

        guard case .nothing(let reason) = TranscriptionModelFamily.parakeet.capabilities else {
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

    @Test("A family's settings survive the Default moving away and back, a relaunch, and a removal")
    func settingsStayWithTheirFamily() async {
        let suiteName = "vcdr.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        let configured = TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "Parakeet")

        settings.transcriptionSettings.modelSettings[.whisper] = configured
        settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo
        settings.transcriptionSettings.defaultModel = .parakeetV3

        // Parakeet being the Default gives it nothing of Whisper's.
        #expect(settings.transcriptionSettings.modelSettings[.parakeet] == .default)

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
        #expect(relaunched.transcriptionSettings.modelSettings[.whisper] == configured)
    }

    @Test("What one Whisper is told is what every Whisper is told")
    func settingsAreTheWholeFamilysAsSoonAsOneIsTold() {
        var settings = TranscriptionSettings.default
        let told = TranscriptionModelSettings(languageHint: .russian, freeTextPrompt: "VCDR, Parakeet")

        // Said once, while whichever Whisper the Library offers first is the
        // one on screen.
        settings.modelSettings[.whisper] = told

        for whisper in TranscriptionProviderRegistry.offeredModels where whisper.family == .whisper {
            var mode = Mode.makeDefault()
            mode.transcriptionOverride.model = whisper
            #expect(settings.effectiveTranscription(for: mode) == EffectiveTranscription(
                model: whisper,
                settings: told
            ))
        }

        // Parakeet is a family of one and hears none of it.
        #expect(settings.modelSettings[.parakeet] == .default)
    }

    @Test("Settings an older build stored against Whisper Large v3 Turbo are the Whisper family's")
    func settingsStoredBeforeFamiliesAreAdopted() {
        let suiteName = "vcdr.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        // What a build that keyed by model wrote — alongside a key belonging to
        // a family this build has never heard of, which a downgrade still needs.
        defaults.set(Data("""
        {"byModel":{"whisper-large-v3-turbo":{"languageHint":"ru","freeTextPrompt":"VCDR, Parakeet"},\
        "canary":{"languageHint":"de","freeTextPrompt":"Canary"}}}
        """.utf8), forKey: "transcriptionModelSettings")

        let upgraded = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())

        #expect(upgraded.transcriptionSettings.modelSettings[.whisper] == TranscriptionModelSettings(
            languageHint: .russian,
            freeTextPrompt: "VCDR, Parakeet"
        ))

        // Saving is where a carried-through key would be dropped, so the check
        // is made after one.
        upgraded.transcriptionSettings.defaultModel = .whisperLargeV3Turbo
        let saved = String(data: defaults.data(forKey: "transcriptionModelSettings")!, encoding: .utf8)!
        #expect(saved.contains("canary"))
        #expect(saved.contains("whisper-large-v3-turbo") == false)
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
