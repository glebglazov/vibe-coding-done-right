import Foundation
import Testing
@testable import vcdr_mac

@Suite("Mode Transcription Override")
@MainActor
struct ModeTranscriptionOverrideTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("A Mode records with the model it pins, told its family's settings under its own patch")
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

        // The Mode pins Whisper and sets one setting for itself; the Default is
        // untouched and stays Parakeet.
        env.overrideActiveMode(with: .whisperLargeV3Turbo) { $0.languageHint = .russian }

        #expect(await record(with: env)?.finalText == "from whisper ")
        #expect(env.settings.transcriptionSettings.defaultModel == .parakeetUltra)
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

        mode.transcriptionOverride.model = .parakeetUltra
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

    @Test("Pinning a model on a Mode's screen moves a pointer and installs nothing")
    func pinningAModelInstallsNothing() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        // The only model this Mac has is the one the Mode is about to pin —
        // which is the only kind the select offers it.
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let before = env.library.entries.map(\.state)

        let override = env.library.override(.none, pinnedTo: .whisperLargeV3Turbo)

        #expect(override.model == .whisperLargeV3Turbo)
        // Two reads' worth of chances for an install to have started.
        await env.library.refresh()
        await env.library.refresh()
        #expect(env.library.entries.map(\.state) == before)
        #expect(await env.whisper.hasTakenItsTurn == false)
        #expect(await env.parakeet.hasTakenItsTurn == false)
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

    @Test("Removing a model Modes pin discloses those Modes, the model and what they will use instead — and until it is agreed to, removes nothing")
    func pinnedRemovalDisclosesBothEndsAndWaits() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let modes = [
            pinningMode("Email", .whisperLargeV3Turbo),
            pinningMode("Notes", .whisperLargeV3Turbo),
            pinningMode("Shell", nil)
        ]
        env.settings.modes = modes

        let removal = env.library.pinnedModelRemoval(for: .whisperLargeV3Turbo)

        #expect(removal?.pinningModes == ["Email", "Notes"])
        #expect(removal?.disclosure == "Email and Notes pin Whisper Large v3 Turbo. "
            + "Remove it and they will use Parakeet Ultra (the Default Model).")
        // Declining is having read it and stopped here: nothing has moved.
        #expect(await env.whisper.isInstalled)
        #expect(env.settings.modes == modes)
    }

    @Test("Agreeing to a pinned removal deletes the model and unpins those Modes, which then follow the Default")
    func agreeingUnpinsAndLeavesTheModesOnTheDefault() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        var email = pinningMode("Email", .whisperLargeV3Turbo)
        email.transcriptionOverride[.whisper].languageHint = .russian
        env.settings.modes = [email, pinningMode("Notes", .whisperLargeV3Turbo), pinningMode("Shell", nil)]

        #expect(await env.library.remove(.whisperLargeV3Turbo) == nil)

        #expect(await env.whisper.isInstalled == false)
        #expect(env.settings.modes.allSatisfy { $0.transcriptionOverride.model == nil })
        // The unpin cleared the model and nothing else it carried.
        #expect(env.settings.modes[0].transcriptionOverride[.whisper].languageHint == .russian)

        // Those Modes follow the Default now, and move with it.
        let unpinned = env.settings.modes[0]
        #expect(env.settings.transcriptionSettings.effectiveTranscription(for: unpinned).model == .parakeetUltra)
        env.settings.transcriptionSettings.defaultModel = .whisperLargeV3Turbo
        #expect(env.settings.transcriptionSettings.effectiveTranscription(for: unpinned).model
            == .whisperLargeV3Turbo)
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

    @Test("A Mode persisted before Modes could pin a model records with the Default")
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

    private func pinningMode(_ name: String, _ model: TranscriptionModel?) -> Mode {
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
