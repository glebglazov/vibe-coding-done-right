import Foundation
import Testing
@testable import vcdr_mac

/// ⇧⎋ while recording is a Discard: the session is idle at once, and the words
/// go to History as a Discarded Conversation that can be processed later.
@Suite("CaptureSession — Discard")
struct CaptureSessionDiscardTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)
    private static let preparationSettleDuration: Duration = .milliseconds(200)

    @Test("A Discard while recording is idle at once, and the next start records")
    @MainActor
    func discardIsIdleAtOnceAndANewStartRecords() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "first words")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })

        #expect(env.hotkeyRegistry.press(env.settings.cancelRecordingHotkey))
        #expect(env.session.status.phase == .idle)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
    }

    @Test("A discarded recording is saved verbatim with the Mode and Style it would have used")
    @MainActor
    func discardSavesVerbatimWordsAndTheRecordedChoice() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "um so the plan is uh done")
        )
        defer { env.cleanup() }
        env.settings.removeFillerWords = true
        let mode = env.settings.activeMode

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)
        env.session.cancel()
        await env.discardedCaptures.awaitFinalizations()

        let saved = env.history.conversations
        #expect(saved.count == 1)
        #expect(saved.first?.inputText == "um so the plan is uh done")
        #expect(saved.first?.output == nil)
        let style: Style? = mode.appliesStyles ? .casual : nil
        let expectedChoice = RecordedOutputChoice(
            platform: .mac,
            modeID: mode.id.uuidString,
            styleID: style?.id.uuidString,
            displayLabel: [mode.name, style?.name].compactMap { $0 }.joined(separator: " · ")
        )
        #expect(saved.first?.status == .discarded(expectedChoice))
    }

    @Test("A discarded recording with no speech saves nothing")
    @MainActor
    func discardWithNoSpeechSavesNothing() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "  ")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        env.session.cancel()
        await env.discardedCaptures.awaitFinalizations()

        #expect(await env.mockProvider.transcribeCallCount == 1)
        #expect(env.history.conversations.isEmpty)
    }

    @Test("A run is not held up by a discarded recording whose model is still downloading")
    @MainActor
    func runIsNotHeldUpByADiscardedRecordingsModel() async throws {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "next words"),
            alternateProvider: MockTranscriptionProvider(
                model: .whisperLargeV3Turbo,
                isReady: false,
                preparationPhase: .downloadingModel,
                result: "discarded words"
            )
        )
        defer { env.cleanup() }

        env.overrideActiveMode(with: .whisperLargeV3Turbo)
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)
        env.session.cancel()

        var mode = env.settings.activeMode
        mode.transcriptionOverride.model = nil
        env.settings.modes[try #require(env.settings.modes.firstIndex { $0.id == mode.id })] = mode

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)
        env.session.toggle()
        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))

        #expect(outcome?.finalText == "next words ")
        #expect(await env.alternateProvider.transcribeCallCount == 0)

        env.alternateProvider.becomeReady()
        await env.discardedCaptures.awaitFinalizations()
        #expect(env.history.conversations.contains { $0.inputText == "discarded words" && $0.status.isDiscarded })
    }

    @Test("A Discard while preparing to record saves nothing and leaves the microphone off")
    @MainActor
    func discardWhilePreparingSavesNothing() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "never said")
        )
        defer { env.cleanup() }
        env.fakePanel.onShow = { [session = env.session] in
            #expect(session.status.phase == .preparingToRecord)
            session.cancel()
        }

        env.session.toggle()
        try? await Task.sleep(for: Self.preparationSettleDuration)

        #expect(env.session.status.phase == .idle)
        #expect(!env.audioRecorder.isRecording)
        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .discarded)
        await env.discardedCaptures.awaitFinalizations()
        #expect(await env.mockProvider.transcribeCallCount == 0)
        #expect(env.history.conversations.isEmpty)
    }
}

/// "Process with AI" turns a Discarded Conversation into a normal entry.
@Suite("ConversationReprocessor")
struct ConversationReprocessorTests {

    @MainActor
    private func makeReprocessor(_ env: CaptureSessionTestEnvironment) -> PipelineConversationReprocessor {
        PipelineConversationReprocessor(
            history: env.history,
            settings: env.settings,
            substitutionStore: SubstitutionStoreProxy(),
            aiPort: env.scriptedAI,
            styleWithID: { _ in nil },
            currentStyle: { .casual }
        )
    }

    @MainActor
    private func recordDiscarded(_ env: CaptureSessionTestEnvironment, text: String) -> Conversation? {
        let mode = env.settings.activeMode
        let id = UUID()
        env.history.recordDiscarded(
            conversationID: id,
            inputSegments: [InputSegment(text: text)],
            choice: RecordedOutputChoice(platform: .mac, modeID: mode.id.uuidString, styleID: nil, displayLabel: mode.name)
        )
        return env.history.conversations.first { $0.id == id }
    }

    @Test("Processing a Discarded Conversation gives it output and makes it normal")
    @MainActor
    func processingMakesItNormal() async throws {
        let env = CaptureSessionTestEnvironment(aiResults: [.success("The plan is done.")], modeProcessing: .cloudAI)
        defer { env.cleanup() }
        let reprocessor = makeReprocessor(env)
        let discarded = try #require(recordDiscarded(env, text: "um so the plan is uh done"))

        await reprocessor.process(discarded, with: nil)

        let processed = try #require(env.history.conversations.first { $0.id == discarded.id })
        #expect(processed.status == .normal)
        #expect(processed.output?.contains("plan is done") == true)
        #expect(processed.label == env.settings.activeMode.name)
        #expect(processed.inputText == "um so the plan is uh done")
        #expect(processed.capturedAt == discarded.capturedAt)
        let calls = await env.scriptedAI.receivedCalls
        #expect(calls.count == 1)
        #expect(calls.first?.structuredText.contains("the plan is") == true)
        #expect(reprocessor.processingIDs.isEmpty)
    }

    @Test("A failed AI call leaves the entry discarded and names the failure")
    @MainActor
    func failureLeavesItDiscarded() async throws {
        let env = CaptureSessionTestEnvironment(aiResults: [], modeProcessing: .cloudAI)
        defer { env.cleanup() }
        let reprocessor = makeReprocessor(env)
        let discarded = try #require(recordDiscarded(env, text: "keep these words"))

        await reprocessor.process(discarded, with: nil)

        let after = try #require(env.history.conversations.first { $0.id == discarded.id })
        #expect(after.status.isDiscarded)
        #expect(after.output == nil)
        #expect(reprocessor.failures[discarded.id] != nil)
        #expect(reprocessor.processingIDs.isEmpty)
    }
}
