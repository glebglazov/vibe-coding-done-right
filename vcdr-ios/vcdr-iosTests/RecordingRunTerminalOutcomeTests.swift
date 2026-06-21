import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingRun terminal outcome seam")
struct RecordingRunTerminalOutcomeTests {
    @Test("success records payload and publishes bundled keyboard result")
    func success() async {
        let settings = Self.makeSettings()
        let captures = ["selected context"]
        let rawTranscript = "hello world"
        let cleanedTranscript = TextPostProcessor.removeFillers(from: rawTranscript)
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success(rawTranscript)),
            settings: settings,
            captures: captures
        )

        #expect(await run.start())
        _ = await run.stop(deliversToKeyboard: false)

        guard case .success(let success) = await run.waitForIdle(timeout: .seconds(1)) else {
            Issue.record("Expected success outcome")
            return
        }
        #expect(success.transcript == cleanedTranscript)
        #expect(success.processed == nil)
        #expect(success.finalText == TranscriptProcessor.finalize(cleanedTranscript, settings: settings))
        #expect(success.captures == captures)
        #expect(keyboard.interactions == [.publishBundledResult(success.finalText)])
    }

    @Test("empty transcription records Empty Result and publishes it to keyboard")
    func emptyResult() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success(""))
        )

        #expect(await run.start())
        _ = await run.stop(deliversToKeyboard: false)

        #expect(await run.waitForIdle(timeout: .seconds(1)) == .emptyResult)
        #expect(keyboard.interactions == [.publish(.emptyResult)])
    }

    @Test("cancellation accessor polls until rest and publishes idle to keyboard")
    func cancellation() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("unused"))
        )

        Task {
            await Task.yield()
            _ = await run.cancel()
        }

        #expect(await run.waitForIdle(timeout: .seconds(1)) == .cancellation)
        #expect(keyboard.interactions == [.publish(.idle)])
    }

    @Test("processing failure records message payload and publishes idle to keyboard")
    func processingFailure() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .failure(ForcedFailure()))
        )

        #expect(await run.start())
        _ = await run.stop(deliversToKeyboard: false)

        let expected = RecordingRunTerminalState.processingFailure(
            RecordingRunFailure(message: "Transcription failed: forced failure")
        )
        #expect(await run.waitForIdle(timeout: .seconds(1)) == expected)
        #expect(keyboard.interactions == [.publish(.idle)])
    }

    @Test("accessor returns nil when the run has not reached rest")
    func waitForIdleTimesOut() async {
        let (run, _) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("unused"))
        )

        #expect(await run.waitForIdle(timeout: .milliseconds(1)) == nil)
    }

    private func makeRun(
        streaming: any RecordingStreamingSession,
        settings: RecordingRun.Settings? = nil,
        captures: [String] = []
    ) -> (RecordingRun, FakeKeyboardChannel) {
        let settings = settings ?? Self.makeSettings()
        let keyboard = FakeKeyboardChannel()
        let run = RecordingRun(
            audioRecorder: FakeRecordingAudioCapture(),
            transcriptionProvider: UnusedStreamingTranscriptionProvider(),
            streaming: streaming,
            transcriptProcessor: TranscriptProcessor(
                makeAIProvider: { _ in
                    ProviderCascade(
                        primary: FakeLLMProvider(behavior: .alwaysSucceed(output: "unused")),
                        fallback: nil,
                        maxAttempts: 1,
                        timeout: .seconds(1)
                    )
                },
                onAIProcessingStatus: { _ in },
                onAIInputText: { _ in }
            ),
            completionAdapters: [
                KeyboardChannelRecordingRunCompletionAdapter(
                    keyboardChannel: keyboard,
                    deliversToKeyboard: true
                )
            ],
            currentSettings: { settings },
            currentCaptures: { captures },
            onLiveTranscript: { _ in },
            onInterimResult: { _ in },
            onTranscribingMessage: { _ in }
        )
        return (run, keyboard)
    }

    private static func makeSettings() -> RecordingRun.Settings {
        RecordingRun.Settings(
            promptMode: .verbatim,
            textStyle: .casual,
            hasAICapability: false
        )
    }
}

@MainActor
private final class FakeRecordingAudioCapture: RecordingAudioCapturing {
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        true
    }

    func stopCapture() {}
}

private actor FakeRecordingStreamingSession: RecordingStreamingSession {
    let result: Result<String, any Error>

    init(result: Result<String, any Error>) {
        self.result = result
    }

    func start(using transcriptionProvider: any StreamingTranscriptionProvider) async throws {}

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        try result.get()
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private struct UnusedStreamingTranscriptionProvider: StreamingTranscriptionProvider {
    func initialize() async throws {}

    var loadedModels: AsrModels? { get async { nil } }
}

private struct ForcedFailure: LocalizedError {
    var errorDescription: String? { "forced failure" }
}
