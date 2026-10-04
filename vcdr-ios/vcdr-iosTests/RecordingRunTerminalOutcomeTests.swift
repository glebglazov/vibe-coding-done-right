import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingRun terminal outcome seam")
struct RecordingRunTerminalOutcomeTests {
    @Test("success records payload and publishes bundled keyboard result")
    func success() async {
        let settings = Self.makeSettings(promptMode: .assistant)
        let captures = ["selected context"]
        let rawTranscript = "hello world"
        let cleanedTranscript = TextPostProcessor.removeFillers(from: rawTranscript)
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success(rawTranscript)),
            settings: settings,
            captures: captures
        )

        #expect(await run.start())
        _ = await run.stop()

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

    @Test("a run outside Assistant drops its Captures")
    func verbatimDropsCaptures() async {
        let (run, _) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("hello world")),
            settings: Self.makeSettings(promptMode: .verbatim),
            captures: ["selected context"]
        )

        #expect(await run.start())
        _ = await run.stop()

        guard case .success(let success) = await run.waitForIdle(timeout: .seconds(1)) else {
            Issue.record("Expected success outcome")
            return
        }
        #expect(success.captures.isEmpty)
    }

    @Test("substitution rewrites the transcript before output and keyboard delivery")
    func substitutionAppliesAcrossAppAndKeyboard() async {
        let settings = Self.makeSettings()
        let substitutions = [
            Substitution(triggerPhrase: "btw", replacement: "by the way")
        ]
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("btw hello")),
            settings: settings,
            substitutions: substitutions
        )

        #expect(await run.start())
        _ = await run.stop()

        guard case .success(let success) = await run.waitForIdle(timeout: .seconds(1)) else {
            Issue.record("Expected success outcome")
            return
        }
        // App path: the dictated Trigger Phrase is swapped for its Replacement.
        // Compared case-insensitively because deterministic finalization may
        // sentence-case the leading word; the swap itself is what matters here.
        #expect(success.transcript.lowercased() == "by the way hello")
        #expect(!success.transcript.lowercased().contains("btw"))
        // Keyboard path: the extension receives the already-substituted text
        // via the Bundled Result — it never reads the Substitution store.
        #expect(keyboard.interactions == [.publishBundledResult(success.finalText)])
        #expect(success.finalText.lowercased().contains("by the way hello"))
    }

    @Test("empty transcription records Empty Result and publishes it to keyboard")
    func emptyResult() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success(""))
        )

        #expect(await run.start())
        _ = await run.stop()

        #expect(await run.waitForIdle(timeout: .seconds(1)) == .emptyResult)
        #expect(keyboard.interactions == [.publish(.emptyResult)])
    }

    @Test("cancellation accessor polls until rest and publishes cancellation to keyboard")
    func cancellation() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("unused"))
        )

        Task {
            await Task.yield()
            _ = await run.cancel()
        }

        #expect(await run.waitForIdle(timeout: .seconds(1)) == .cancellation)
        #expect(keyboard.interactions == [.publish(.cancelled)])
    }

    @Test("processing failure records message payload and publishes it with its reason")
    func processingFailure() async {
        let (run, keyboard) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .failure(ForcedFailure()))
        )

        #expect(await run.start())
        _ = await run.stop()

        let expected = RecordingRunTerminalState.processingFailure(
            RecordingRunFailure(message: "Transcription failed: forced failure")
        )
        #expect(await run.waitForIdle(timeout: .seconds(1)) == expected)
        // The reason the app shows reaches the keyboard as the failure payload —
        // it is not discarded at the process boundary (ADR-0004).
        #expect(keyboard.interactions == [.publishFailure("Transcription failed: forced failure")])
    }

    @Test("accessor returns nil when the run has not reached rest")
    func waitForIdleTimesOut() async {
        let (run, _) = makeRun(
            streaming: FakeRecordingStreamingSession(result: .success("unused"))
        )

        #expect(await run.waitForIdle(timeout: .milliseconds(1)) == nil)
        _ = await run.cancel()
    }

    private func makeRun(
        streaming: any RecordingStreamingSession,
        settings: RecordingRun.Settings? = nil,
        captures: [String] = [],
        substitutions: [Substitution] = []
    ) -> (RecordingRun, FakeKeyboardChannel) {
        let settings = settings ?? Self.makeSettings()
        let keyboard = FakeKeyboardChannel()
        let run = RecordingRun(
            audioRecorder: FakeRecordingAudioCapture(),
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
                    origin: .keyboard
                )
            ],
            currentSettings: { settings },
            currentCaptures: { captures },
            currentSubstitutions: { substitutions },
            onLiveTranscript: { _ in },
            onInterimResult: { _ in },
            onTranscribingMessage: { _ in }
        )
        return (run, keyboard)
    }

    private static func makeSettings(promptMode: AIPromptMode = .verbatim) -> RecordingRun.Settings {
        RecordingRun.Settings(
            promptMode: promptMode,
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

private struct ForcedFailure: LocalizedError {
    var errorDescription: String? { "forced failure" }
}
