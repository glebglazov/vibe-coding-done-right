import FluidAudio
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingRun")
struct RecordingRunTests {
    @Test("cancellation reaches the completion seam")
    func cancellationReachesCompletionSeam() async {
        let adapter = SpyCompletionAdapter()
        let run = RecordingRun(
            audioRecorder: AudioRecorder(),
            transcriptionProvider: FakeStreamingTranscriptionProvider(),
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
            completionAdapters: [adapter],
            currentSettings: {
                RecordingRun.Settings(
                    promptMode: .verbatim,
                    textStyle: .casual,
                    hasAICapability: false
                )
            },
            currentCaptures: { [] },
            onLiveTranscript: { _ in },
            onInterimResult: { _ in },
            onTranscribingMessage: { _ in }
        )

        let terminalState = await run.cancel()

        #expect(terminalState == .cancellation)
        #expect(adapter.states == [.cancellation])
    }

    @Test("keyboard adapter publishes each terminal state as its own wire state")
    func keyboardAdapterMapsTerminalStates() async {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)
        let adapter = KeyboardChannelRecordingRunCompletionAdapter(
            keyboardChannel: channel,
            deliversToKeyboard: true
        )

        await adapter.complete(.success(success(finalText: "hello ")))
        #expect(channel.readState() == .bundledResult("hello "))

        await adapter.complete(.emptyResult)
        #expect(channel.readState() == .emptyResult)

        await adapter.complete(.cancellation)
        #expect(channel.readState() == .cancelled)

        // The reason the app shows the user is the reason on the wire — the
        // keyboard's FAILED pill and the app's error text are one fact.
        await adapter.complete(.processingFailure(
            RecordingRunFailure(message: "Transcription unavailable: model load failed")
        ))
        #expect(channel.readState() == .failed("Transcription unavailable: model load failed"))
    }

    @Test("a run that does not deliver to the keyboard is the only publisher of idle")
    func keyboardAdapterPublishesIdleOnlyWhenNotDelivering() async {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)
        let adapter = KeyboardChannelRecordingRunCompletionAdapter(
            keyboardChannel: channel,
            deliversToKeyboard: false
        )

        // Driven from the app surface, which already shows the outcome: the
        // keyboard has nothing to render, so the channel comes back to idle
        // rather than carrying a terminal state the keyboard would flash.
        for terminal: RecordingRunTerminalState in [
            .success(success(finalText: "hello ")),
            .emptyResult,
            .cancellation,
            .processingFailure(RecordingRunFailure(message: "failed"))
        ] {
            channel.publish(.transcribing)
            await adapter.complete(terminal)
            #expect(channel.readState() == .idle)
        }
    }

    @Test("history adapter records successful runs only")
    func historyAdapterRecordsSuccessOnly() async {
        let history = FileHistoryStore(storageRoot: temporaryHistoryRoot())
        let adapter = HistoryRecordingRunCompletionAdapter(history: history)

        await adapter.complete(.processingFailure(RecordingRunFailure(message: "failed")))
        #expect(history.conversations.isEmpty)

        await adapter.complete(.success(success(
            transcript: "raw text",
            processed: "processed text",
            finalText: "final text",
            captures: ["selected context"],
            historyLabel: "Dictation · Casual"
        )))

        let conversation = try! #require(history.conversations.first)
        #expect(conversation.inputSegments.count == 2)
        #expect(conversation.output == "final text")
        #expect(conversation.label == "Dictation · Casual")
    }

    @Test("history adapter holds successful runs until bootstrap completes")
    func historyAdapterFlushesPendingSuccesses() async {
        let history = FileHistoryStore(storageRoot: temporaryHistoryRoot())
        let adapter = HistoryRecordingRunCompletionAdapter()

        let pendingSuccess = success(
            transcript: "raw text",
            processed: "processed text",
            finalText: "pending text",
            captures: ["selected context", ""],
            historyLabel: "Dictation · Formal"
        )
        await adapter.complete(.success(pendingSuccess))
        #expect(history.conversations.isEmpty)

        adapter.setHistory(history)

        let conversation = try! #require(history.conversations.first)
        #expect(history.conversations.count == 1)
        #expect(conversation.id == pendingSuccess.conversationID)
        #expect(conversation.inputSegments[0].text == "raw text")
        #expect(conversation.inputSegments[1].capture?.text == "selected context")
        #expect(conversation.inputSegments[1].capture?.source == .selection)
        #expect(conversation.output == "pending text")
        #expect(conversation.label == "Dictation · Formal")
    }

    @Test("history adapter does not duplicate runs when bootstrap finishes first")
    func historyAdapterRecordsOnceAfterBootstrap() async {
        let history = FileHistoryStore(storageRoot: temporaryHistoryRoot())
        let adapter = HistoryRecordingRunCompletionAdapter()
        adapter.setHistory(history)

        await adapter.complete(.success(success(
            transcript: "raw",
            processed: "processed",
            finalText: "normal path"
        )))

        #expect(history.conversations.count == 1)
        #expect(history.conversations.first?.copyableText == "normal path")
    }

    @Test("history adapter does not buffer unsuccessful terminal states")
    func historyAdapterDoesNotBufferUnsuccessfulStates() async {
        let history = FileHistoryStore(storageRoot: temporaryHistoryRoot())
        let adapter = HistoryRecordingRunCompletionAdapter()

        await adapter.complete(.emptyResult)
        await adapter.complete(.cancellation)
        await adapter.complete(.processingFailure(RecordingRunFailure(message: "failed")))
        adapter.setHistory(history)

        #expect(history.conversations.isEmpty)
    }

    private func success(
        transcript: String = "raw",
        processed: String? = nil,
        finalText: String = "final",
        captures: [String] = [],
        historyLabel: String? = nil
    ) -> RecordingRunSuccess {
        RecordingRunSuccess(
            conversationID: UUID(),
            transcript: transcript,
            processed: processed,
            finalText: finalText,
            captures: captures,
            historyLabel: historyLabel
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RecordingRunTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryHistoryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingRunTests-\(UUID().uuidString)")
    }
}

@MainActor
private final class SpyCompletionAdapter: RecordingRunCompletionAdapter {
    private(set) var states: [RecordingRunTerminalState] = []

    func complete(_ terminalState: RecordingRunTerminalState) async {
        states.append(terminalState)
    }
}

private struct FakeStreamingTranscriptionProvider: StreamingTranscriptionProvider {
    func initialize() async throws {}
    var loadedModels: AsrModels? { get async { nil } }
}
