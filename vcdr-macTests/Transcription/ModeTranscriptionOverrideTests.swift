import Foundation
import Testing
@testable import vcdr_mac

@Suite("Mode Transcription Override")
@MainActor
struct ModeTranscriptionOverrideTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("A Mode records with the model it names, told its family's settings under its own patch")
    func overrideDecidesTheModelAndWhatItIsTold() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "from parakeet"),
            alternateProvider: MockTranscriptionProvider(
                model: .whisperLargeV3Turbo,
                result: "from whisper"
            )
        )
        defer { env.cleanup() }
        env.settings.transcriptionSettings.modelSettings[.whisper] =
            TranscriptionModelSettings(languageHint: .detect, freeTextPrompt: "Parakeet")

        // The Mode names Whisper and sets one setting for itself; the Default is
        // untouched and stays Parakeet.
        env.overrideActiveMode(with: .whisperLargeV3Turbo) { $0.languageHint = .russian }

        #expect(await record(with: env)?.finalText == "from whisper ")
        #expect(env.settings.transcriptionSettings.defaultModel == .parakeetV3)
        #expect(await env.mockProvider.transcribeCallCount == 0)
        #expect(await env.alternateProvider.receivedSettings?.languageHint == .russian)
        // Unset here, so it followed the family's own value all the way down.
        #expect(await env.alternateProvider.receivedSettings?.freeTextPrompt == "Parakeet")

        // Editing the family's own settings reaches the Mode, because what the
        // Mode never set was never copied.
        env.settings.transcriptionSettings.modelSettings[.whisper].freeTextPrompt = "VCDR"

        _ = await record(with: env)
        #expect(await env.alternateProvider.receivedSettings?.freeTextPrompt == "VCDR")
        #expect(await env.alternateProvider.receivedSettings?.languageHint == .russian)
    }

    @Test("A Mode's settings for a family survive it being pointed elsewhere and back")
    func patchesSurviveRepointing() {
        var mode = Mode.makeDefault()
        mode.transcriptionOverride.model = .whisperLargeV3Turbo
        mode.transcriptionOverride[.whisper].languageHint = .russian

        mode.transcriptionOverride.model = .parakeetV3
        mode.transcriptionOverride.model = nil
        mode.transcriptionOverride.model = .whisperLargeV3Turbo

        #expect(mode.transcriptionOverride[.whisper].languageHint == .russian)

        let settings = TranscriptionSettings.default
        #expect(settings.effectiveTranscription(for: mode).settings.languageHint == .russian)
    }

    @Test("A setting is either this Mode's own or the family's, and one of its own can be given back")
    func provenanceIsPerSetting() {
        var settings = TranscriptionSettings.default
        settings.modelSettings[.whisper] =
            TranscriptionModelSettings(languageHint: .german, freeTextPrompt: "Parakeet")
        var mode = Mode.makeDefault()
        mode.transcriptionOverride.model = .whisperLargeV3Turbo
        mode.transcriptionOverride[.whisper].languageHint = .russian

        let patch = mode.transcriptionOverride[.whisper]
        #expect(patch.isSet(.languageHint))
        #expect(patch.isSet(.freeTextPrompt) == false)

        mode.transcriptionOverride[.whisper].clear(.languageHint)

        #expect(mode.transcriptionOverride[.whisper].isSet(.languageHint) == false)
        #expect(settings.effectiveTranscription(for: mode).settings.languageHint == .german)
    }

    @Test("Naming a model a Mode does not have downloads it there and then, with progress")
    func namingAModelInstallsIt() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        // The Mode's screen is open, which is what keeps the row it shows fresh.
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .notInstalled })

        let override = env.library.override(.none, naming: .whisperLargeV3Turbo)

        #expect(override.model == .whisperLargeV3Turbo)
        await env.whisper.beginDownload(progress: 0.25)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .downloading(.fraction(0.25)) })

        // The Library never cancels a download, so the held-open preparation is
        // finished here rather than outliving the test.
        await env.whisper.becomeReady()
    }

    @Test("A Mode whose model is absent still records, waits and narrates — and never uses the Default")
    func absentOverrideModelStillRecords() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "from parakeet"),
            alternateProvider: MockTranscriptionProvider(
                model: .whisperLargeV3Turbo,
                isReady: false,
                preparationPhase: .downloadingModel,
                result: "from whisper",
                holdsPreparationOpen: true
            )
        )
        defer { env.cleanup() }
        env.overrideActiveMode(with: .whisperLargeV3Turbo)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        #expect(env.preparedModels.models.contains(.whisperLargeV3Turbo))
        #expect(await waitFor { env.narratedPreparation.contains { $0.hasPrefix("Downloading model") } })

        try? await Task.sleep(for: Self.testRecordingDuration)
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .transcribing })
        #expect(await env.mockProvider.transcribeCallCount == 0)

        await env.alternateProvider.becomeReady()

        #expect(await env.waitForRest())
        #expect(await env.session.waitForNextIdle(timeout: .seconds(2))?.finalText == "from whisper ")
        #expect(await env.mockProvider.transcribeCallCount == 0)
    }

    @Test("Removing a model a Mode names is refused, and the refusal names the Modes")
    func removalNamesTheModes() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        env.settings.modes = [
            namingMode("Email", .whisperLargeV3Turbo),
            namingMode("Notes", .whisperLargeV3Turbo),
            namingMode("Shell", nil)
        ]

        let refusal = await env.library.remove(.whisperLargeV3Turbo)

        #expect(refusal == .namedByModes(["Email", "Notes"]))
        #expect(refusal?.message.contains("Email and Notes") == true)
        #expect(await env.whisper.isInstalled)

        // Nothing names it once those Modes are pointed elsewhere.
        env.settings.modes = [namingMode("Shell", nil)]
        #expect(await env.library.remove(.whisperLargeV3Turbo) == nil)
        #expect(await env.whisper.isInstalled == false)
    }

    @Test("A Mode's patch written against Whisper Large v3 Turbo is the Whisper family's after upgrading")
    func patchesWrittenBeforeFamiliesAreAdopted() throws {
        let legacy = Data("""
        {"model":"whisper-large-v3-turbo",\
        "patches":{"whisper-large-v3-turbo":{"languageHint":"ru"},"canary":{"languageHint":"de"}}}
        """.utf8)

        let override = try JSONDecoder().decode(TranscriptionOverride.self, from: legacy)

        #expect(override[.whisper].languageHint == .russian)
        // The family this build does not know keeps its patch rather than
        // failing the decode of every Mode.
        let rewritten = String(data: try JSONEncoder().encode(override), encoding: .utf8)!
        #expect(rewritten.contains("canary"))
    }

    @Test("A Mode persisted before Modes could name a model records with the Default")
    func modesWrittenBeforeThisDecodeToTheDefault() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","name":"Legacy","isDisabled":false,\
        "processingType":"none","processingCommand":"","systemPromptEnabled":false,\
        "systemPrompt":"","aiProvider":"anthropic","promptType":"dictation",\
        "localAgentProvider":"claudeCode","localAgentPassVariables":false,\
        "defaultOutputDestinationID":"\(OutputDestination.builtInCopyID.uuidString)",\
        "parameters":[],"showPreview":false,"saveResultToClipboard":false,\
        "appliesStyles":true,"contextAware":false,"appendCapturesToOutput":false}
        """.utf8)

        let mode = try JSONDecoder().decode(Mode.self, from: legacy)

        #expect(mode.transcriptionOverride == .none)
        var settings = TranscriptionSettings.default
        settings.defaultModel = .whisperLargeV3Turbo
        settings.modelSettings[.whisper] = TranscriptionModelSettings(languageHint: .german)
        #expect(settings.effectiveTranscription(for: mode) == EffectiveTranscription(
            model: .whisperLargeV3Turbo,
            settings: TranscriptionModelSettings(languageHint: .german)
        ))
    }

    // MARK: - Helpers

    private func namingMode(_ name: String, _ model: TranscriptionModel?) -> Mode {
        var mode = Mode(id: UUID(), name: name)
        mode.transcriptionOverride.model = model
        return mode
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

extension CaptureSessionTestEnvironment {

    /// Points the active Mode at `model`, and lets a test set what this Mode
    /// tells it — the two moves the Mode screen makes.
    func overrideActiveMode(
        with model: TranscriptionModel,
        patch: (inout TranscriptionSettingsPatch) -> Void = { _ in }
    ) {
        var mode = settings.activeMode
        mode.transcriptionOverride.model = model
        patch(&mode.transcriptionOverride[model.family])
        settings.modes[settings.modes.firstIndex { $0.id == mode.id }!] = mode
    }

    /// Every preparation line the pill was given, in order.
    var narratedPreparation: [String] {
        fakePanel.calls.compactMap {
            guard case .setPreparationNotice(let line) = $0 else { return nil }
            return line
        }
    }
}
