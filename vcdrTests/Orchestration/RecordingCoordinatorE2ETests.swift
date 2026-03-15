import Foundation
import Testing
@testable import vcdr

// MARK: - Single Cycle Tests

@Suite("RecordingCoordinator E2E — Single Cycle")
struct RecordingCoordinatorSingleCycleTests {

    // MARK: - Constants

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Happy path: start → record → stop → transcribe → idle")
    @MainActor
    func happyPath() async {
        let env = E2ETestEnvironment(mockProvider: MockTranscriptionProvider(result: "Hello world"))
        defer { env.cleanup() }

        env.coordinator.toggleRecording()
        let started = await env.waitForState { $0 == .recording }
        #expect(started, "Should reach .recording state")

        try? await Task.sleep(for: Self.testRecordingDuration)

        env.coordinator.toggleRecording()
        let finished = await env.waitForIdle()
        #expect(finished, "Should return to idle")

        #expect(env.coordinator.state == .idle)
        #expect(env.results.completed.count == 1)
        #expect(env.results.completed.first?.text == "Hello world")
    }

    @Test("Empty transcription triggers onTranscriptionFailed")
    @MainActor
    func emptyTranscription() async {
        let env = E2ETestEnvironment(mockProvider: MockTranscriptionProvider(result: ""))
        defer { env.cleanup() }

        env.coordinator.toggleRecording()
        let started = await env.waitForState { $0 == .recording }
        #expect(started)

        try? await Task.sleep(for: Self.testRecordingDuration)

        env.coordinator.toggleRecording()
        let finished = await env.waitForIdle()
        #expect(finished)

        #expect(env.results.completed.isEmpty, "Should not produce a result for empty text")
        #expect(env.results.transcriptionFailedCount == 1)
    }

    @Test("Provider not ready triggers error state")
    @MainActor
    func providerNotReady() async {
        let env = E2ETestEnvironment(mockProvider: MockTranscriptionProvider(isReady: false))
        defer { env.cleanup() }

        env.coordinator.toggleRecording()
        let errored = await env.waitForState { state in
            if case .error = state { return true }
            return false
        }
        #expect(errored, "Should reach error state")

        #expect(env.results.failedMessages.contains("Model still loading..."))
        #expect(env.results.completed.isEmpty)
    }

    @Test("Transcription error triggers error state")
    @MainActor
    func transcriptionError() async {
        let provider = MockTranscriptionProvider(
            error: TranscriptionError.transcriptionFailed("test error")
        )
        let env = E2ETestEnvironment(mockProvider: provider)
        defer { env.cleanup() }

        env.coordinator.toggleRecording()
        let started = await env.waitForState { $0 == .recording }
        #expect(started)

        try? await Task.sleep(for: Self.testRecordingDuration)

        env.coordinator.toggleRecording()
        let errored = await env.waitForState { state in
            if case .error = state { return true }
            return false
        }
        #expect(errored)

        #expect(env.results.completed.isEmpty)
        #expect(!env.results.failedMessages.isEmpty)
    }

    @Test("Filler words are removed when setting is enabled")
    @MainActor
    func fillerWordRemoval() async {
        let provider = MockTranscriptionProvider(
            result: "Um so I was thinking uh that we should fix this"
        )
        let env = E2ETestEnvironment(mockProvider: provider)
        env.settings.removeFillerWords = true
        defer { env.cleanup() }

        env.coordinator.toggleRecording()
        let started = await env.waitForState { $0 == .recording }
        #expect(started)

        try? await Task.sleep(for: Self.testRecordingDuration)

        env.coordinator.toggleRecording()
        let finished = await env.waitForIdle()
        #expect(finished)

        #expect(env.results.completed.count == 1)
        let resultText = env.results.completed.first?.text ?? ""
        #expect(!resultText.contains("Um"))
        #expect(!resultText.contains("uh"))
        #expect(resultText.contains("fix this"))
    }
}

// MARK: - Stress Tests

@Suite("RecordingCoordinator E2E — Stress")
struct RecordingCoordinatorStressTests {

    // MARK: - Constants

    private static let stressLoopIterations = 20
    private static let cancelStormIterations = 30
    private static let testRecordingDuration: Duration = .milliseconds(100)
    private static let interCycleDelay: Duration = .milliseconds(100)
    private static let cancelDelayRange = 10...100

    @Test("Stress loop: 20 sequential cycles complete without errors")
    @MainActor
    func stressLoop() async {
        let env = E2ETestEnvironment(mockProvider: MockTranscriptionProvider(result: "test"))
        defer { env.cleanup() }

        for i in 0..<Self.stressLoopIterations {
            env.coordinator.toggleRecording()
            let started = await env.waitForState { $0 == .recording }
            #expect(started, "Cycle \(i + 1): should reach .recording")

            try? await Task.sleep(for: Self.testRecordingDuration)

            env.coordinator.toggleRecording()
            let finished = await env.waitForIdle()
            #expect(finished, "Cycle \(i + 1): should return to idle")

            #expect(env.coordinator.state == .idle, "Cycle \(i + 1): state should be .idle")

            try? await Task.sleep(for: Self.interCycleDelay)
        }

        #expect(env.results.completed.count == Self.stressLoopIterations)
    }

    @Test("Cancel storm: 30 rapid start+cancel cycles all reach idle")
    @MainActor
    func cancelStorm() async {
        let env = E2ETestEnvironment(mockProvider: MockTranscriptionProvider(result: "test"))
        defer { env.cleanup() }

        for i in 0..<Self.cancelStormIterations {
            env.coordinator.toggleRecording()

            let delay = Duration.milliseconds(Int.random(in: Self.cancelDelayRange))
            try? await Task.sleep(for: delay)

            env.coordinator.cancelRecording()

            let reachedIdle = await env.waitForIdle()
            #expect(reachedIdle, "Cancel storm \(i + 1): should reach idle after cancel")

            // Reset from error state if needed
            if case .error = env.coordinator.state {
                let recovered = await env.waitForState { $0 == .idle }
                #expect(recovered, "Cancel storm \(i + 1): should recover from error")
            }

            try? await Task.sleep(for: Self.interCycleDelay)
        }
    }
}
