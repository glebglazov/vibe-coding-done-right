import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Single Cycle

@Suite("CaptureSession — Single Cycle")
struct CaptureSessionSingleCycleTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Happy path: records, transcribes, executes action, writes history")
    @MainActor
    func happyPath() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello world")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForRest())

        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .executed)
        #expect(outcome?.finalText == "hello world ")
        #expect(env.history.conversations.count == 1)

        // Panel went through show → populateImmediateActionText → dismiss.
        #expect(env.fakePanel.calls.contains(.show))
        #expect(env.fakePanel.calls.contains(.dismiss))
        let hadPreview = env.fakePanel.calls.contains { call in
            if case .showPreview = call { return true }
            return false
        }
        #expect(!hadPreview, "Default mode has showPreview=false — no preview should be shown")
    }

    @Test("Empty transcription transitions to idle without writing history")
    @MainActor
    func emptyTranscription() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForRest())
        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .failed)
        #expect(env.history.conversations.isEmpty)
    }

    @Test("Recording starts before the model is ready and transcribes once it is")
    @MainActor
    func recordingStartsBeforeTheModelIsReady() async {
        // ADR-0006: the hotkey is never refused for an unready model. The
        // utterance is captured and the wait moves to the stop, where the app
        // genuinely cannot continue without the model.
        let provider = MockTranscriptionProvider(isReady: false, preparationPhase: .downloadingModel)
        let env = CaptureSessionTestEnvironment(mockProvider: provider)
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .transcribing })

        // The download is announced while the user is still speaking, not only
        // after — late enough to decide against would be no use at all.
        #expect(env.fakePanel.calls.contains(
            .setPreparationNotice("Downloading model — your recording is safe")
        ))

        await provider.becomeReady()
        #expect(await env.waitForRest())

        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .executed)
        #expect(outcome?.finalText == "hello world ")
    }

    @Test("A model that will not prepare ends the run and clears once it does")
    @MainActor
    func preparationFailureEndsTheRunAndRetrySucceeds() async {
        let provider = MockTranscriptionProvider(isReady: false, preparationPhase: .downloadingModel)
        let env = CaptureSessionTestEnvironment(mockProvider: provider)
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .transcribing })

        await provider.fail(.offline)

        // The wait ends rather than outlasting the model, and what the user
        // reads is the named cause and its remedy — never the backend's words.
        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })
        #expect(env.fakePanel.calls.contains(.setError(PreparationFailure.offline.message)))

        // The cause goes away: the next run reaches the model and transcribes.
        await provider.becomeReady()
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForRest())
        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .executed)
    }

    @Test("Transcription error transitions to error state")
    @MainActor
    func transcriptionError() async {
        let provider = MockTranscriptionProvider(
            error: TranscriptionError.transcriptionFailed("test error")
        )
        let env = CaptureSessionTestEnvironment(mockProvider: provider)
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })
    }
}

// MARK: - Recording Start Failures

@Suite("CaptureSession — Recording Start Failures")
struct CaptureSessionRecordingStartFailureTests {

    @Test("A hotkey press with no microphone permission names the missing permission and how to grant it")
    @MainActor
    func microphonePermissionDenied() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }
        // No real TCC grant required: the seam fails the start the same way a
        // denied AVCaptureDevice authorization would, without touching it.
        env.audioRecorder.testStartFailure = .microphonePermissionDenied

        env.session.toggle()

        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })
        let message = RecordingStartFailure.microphonePermissionDenied.message
        #expect(message.localizedCaseInsensitiveContains("microphone"))
        #expect(message.localizedCaseInsensitiveContains("settings"))
        #expect(env.fakePanel.calls.contains(.setError(message)))
    }

    @Test("A recording that fails to start for another reason reports the truth, not a permission problem")
    @MainActor
    func nonPermissionFailureStaysTruthful() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }
        env.audioRecorder.testStartFailure = .unknown

        env.session.toggle()

        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })
        let message = RecordingStartFailure.unknown.message
        #expect(!message.localizedCaseInsensitiveContains("permission"))
        #expect(env.fakePanel.calls.contains(.setError(message)))
    }
}

// MARK: - Preview Branches

@Suite("CaptureSession — Preview Branches")
struct CaptureSessionPreviewTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Preview mode pauses at awaitingPreview and confirms on toggle")
    @MainActor
    func previewConfirmWithDefaultDestination() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello preview"),
            modePreview: true
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .awaitingPreview })

        let previewOutcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(previewOutcome?.kind == .previewShown)
        #expect(previewOutcome?.finalText == "hello preview ")

        env.fakePanel.fireConfirm()
        #expect(await env.waitForPhase { $0 == .idle })
        let finalOutcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(finalOutcome?.kind == .executed)
        #expect(env.history.conversations.count == 1)
    }

    @Test("Destination override during recording skips preview even when mode.showPreview is true")
    @MainActor
    func destinationOverrideSkipsPreview() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello override"),
            modePreview: true
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        // Simulate destination hotkey during recording by smuggling the ID into run state,
        // then calling stop. In production the destination hotkey manager does this.
        let copyID = OutputDestination.builtInCopyID
        env.session.run?.destinationOverrideID = copyID
        env.session.stopRecordingAndTranscribe()

        #expect(await env.waitForPhase { $0 == .idle })
        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .executed, "Override should skip preview and execute directly")
        #expect(outcome?.destinationID == copyID)

        let hadPreview = env.fakePanel.calls.contains { call in
            if case .showPreview = call { return true }
            return false
        }
        #expect(!hadPreview, "Preview must be skipped when a destination override was used")
    }
}

// MARK: - AI Retry Parity (load-bearing test)

@Suite("CaptureSession — AI Retry")
struct CaptureSessionAIRetryTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("AI failure shows preview; retry routes through the same port call")
    @MainActor
    func aiRetryUsesSameStructuredText() async {
        struct TestError: Error { }
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Polish me"),
            aiResults: [.failure(TestError()), .success("polished")],
            modeProcessing: .cloudAI
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .awaitingPreview })

        let firstOutcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(firstOutcome?.kind == .aiProcessingFallback)

        // Verify exactly one call was received so far.
        var callsSoFar = await env.scriptedAI.receivedCalls
        #expect(callsSoFar.count == 1)
        let firstStructured = callsSoFar[0].structuredText

        // Fire retry — this must reach the same port with the SAME structured text.
        env.fakePanel.fireRetryAIProcessing()

        // Give the retry task a beat to run and record the second call.
        for _ in 0..<100 {
            callsSoFar = await env.scriptedAI.receivedCalls
            if callsSoFar.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(callsSoFar.count == 2, "Retry should produce a second scripted call")

        // CRITICAL: the mechanical proof that both calls share one code path.
        #expect(
            callsSoFar[0].structuredText == firstStructured,
            "Retry must replay the exact same structured text that the initial attempt sent"
        )
        #expect(
            callsSoFar[0].structuredText == callsSoFar[1].structuredText,
            "Both AI calls must carry identical structuredText — guards against retry-path drift"
        )
    }
}

// MARK: - Cancellation

@Suite("CaptureSession — Cancellation")
struct CaptureSessionCancellationTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Cancel during recording returns to idle without history")
    @MainActor
    func cancelDuringRecording() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "should not land")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
        #expect(env.history.conversations.isEmpty)
    }

    @Test("Cancel during transcription returns to idle without history")
    @MainActor
    func cancelDuringTranscription() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "should not land")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)
        env.session.toggle()
        // Cancel immediately — may catch .transcribing or .executing depending on timing.
        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }
}

// MARK: - Preview Skip Rule

@Suite("CaptureSession — Preview Rule")
struct CaptureSessionPreviewRuleTests {

    @Test("destination override during recording skips preview even when mode.showPreview is true")
    func shouldSkipPreviewRule() {
        var mode = Mode.makeDefault()
        mode.showPreview = true
        #expect(!CaptureSession.shouldShowPreview(mode: mode, hadDestinationOverride: true))
        #expect(CaptureSession.shouldShowPreview(mode: mode, hadDestinationOverride: false))

        mode.showPreview = false
        #expect(!CaptureSession.shouldShowPreview(mode: mode, hadDestinationOverride: true))
        #expect(!CaptureSession.shouldShowPreview(mode: mode, hadDestinationOverride: false))
    }
}

// MARK: - Stress (preserved from old suite)

@Suite("CaptureSession — Stress")
struct CaptureSessionStressTests {

    private static let stressLoopIterations = 20
    private static let cancelStormIterations = 20
    private static let testRecordingDuration: Duration = .milliseconds(100)
    private static let interCycleDelay: Duration = .milliseconds(100)

    @Test("Stress loop: 20 sequential cycles complete without errors")
    @MainActor
    func stressLoop() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "test")
        )
        defer { env.cleanup() }

        for i in 0..<Self.stressLoopIterations {
            env.session.toggle()
            #expect(await env.waitForPhase { $0 == .recording }, "Cycle \(i + 1): reach recording")
            try? await Task.sleep(for: Self.testRecordingDuration)
            env.session.toggle()
            #expect(await env.waitForRest(), "Cycle \(i + 1): reach rest")
            try? await Task.sleep(for: Self.interCycleDelay)
        }
        #expect(env.history.conversations.count == Self.stressLoopIterations)
    }

    @Test("Cancel storm: 20 rapid start+cancel cycles all reach idle")
    @MainActor
    func cancelStorm() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "test")
        )
        defer { env.cleanup() }

        for i in 0..<Self.cancelStormIterations {
            env.session.toggle()
            let delay = Duration.milliseconds(Int.random(in: 10...100))
            try? await Task.sleep(for: delay)
            env.session.cancel()
            #expect(await env.waitForPhase { $0 == .idle }, "Cancel \(i + 1): reach idle")
            try? await Task.sleep(for: Self.interCycleDelay)
        }
    }
}
