import Foundation
import AVFoundation
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
            streaming: FakeRecordingStreamingSession(),
            transcriptProcessor: TranscriptProcessor(
                makeAIProvider: {
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
            origin: .keyboard
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
            origin: .app
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
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: temporaryHistoryRoot()))
        let adapter = HistoryRecordingRunCompletionAdapter(history: history)

        await adapter.complete(.processingFailure(RecordingRunFailure(message: "failed")))
        #expect(history.conversations.isEmpty)

        await adapter.complete(.success(success(
            transcript: "raw text",
            processed: "processed text",
            finalText: "final text",
            historyLabel: "AI · Casual"
        )))

        let conversation = try! #require(history.conversations.first)
        #expect(conversation.inputSegments.count == 1)
        #expect(conversation.output == "final text")
        #expect(conversation.label == "AI · Casual")
    }

    @Test("history adapter holds successful runs until bootstrap completes")
    func historyAdapterFlushesPendingSuccesses() async {
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: temporaryHistoryRoot()))
        let adapter = HistoryRecordingRunCompletionAdapter()

        let pendingSuccess = success(
            transcript: "raw text",
            processed: "processed text",
            finalText: "pending text",
            historyLabel: "AI · Formal"
        )
        await adapter.complete(.success(pendingSuccess))
        #expect(history.conversations.isEmpty)

        adapter.setHistory(history)

        let conversation = try! #require(history.conversations.first)
        #expect(history.conversations.count == 1)
        #expect(conversation.id == pendingSuccess.conversationID)
        #expect(conversation.inputSegments.map(\.text) == ["raw text"])
        #expect(conversation.output == "pending text")
        #expect(conversation.label == "AI · Formal")
    }

    @Test("history adapter does not duplicate runs when bootstrap finishes first")
    func historyAdapterRecordsOnceAfterBootstrap() async {
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: temporaryHistoryRoot()))
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
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: temporaryHistoryRoot()))
        let adapter = HistoryRecordingRunCompletionAdapter()

        await adapter.complete(.emptyResult)
        await adapter.complete(.cancellation)
        await adapter.complete(.processingFailure(RecordingRunFailure(message: "failed")))
        adapter.setHistory(history)

        #expect(history.conversations.isEmpty)
    }

    @Test("Arming Deadline with no first buffer terminates as Processing Failure")
    func armingDeadlineWithoutFirstBufferIsProcessingFailure() async {
        let clock = TestClock()
        // Hang inside startCapture so the deadline must fire before engine
        // start returns — the 15:00 failure mode from ADR-0005.
        let capture = ControllableRecordingAudioCapture(hangUntilStopped: true)
        let adapter = SpyCompletionAdapter()
        let run = makeRun(audioRecorder: capture, clock: clock, completionAdapters: [adapter])

        let startTask = Task { await run.start() }
        await settle()
        #expect(clock.sleepCount == 1)
        #expect(!run.isTerminal)

        clock.advance()
        await settle()

        let expected = RecordingRunTerminalState.processingFailure(
            RecordingRunFailure(message: RecordingRun.armingDeadlineFailureMessage)
        )
        #expect(await run.waitForIdle(timeout: .seconds(1)) == expected)
        #expect(adapter.states == [expected])
        #expect(await startTask.value == false)
    }

    @Test("Arming Deadline is keyed on the first buffer, not on engine start returning")
    func armingDeadlineIgnoresEngineStartWithoutBuffer() async {
        let clock = TestClock()
        // Capture returns successfully (engine "started") but never delivers a buffer.
        let capture = ControllableRecordingAudioCapture(startResult: true)
        let adapter = SpyCompletionAdapter()
        let run = makeRun(audioRecorder: capture, clock: clock, completionAdapters: [adapter])

        #expect(await run.start() == true)
        await settle()
        #expect(clock.sleepCount == 1)
        #expect(!run.isTerminal)

        clock.advance()
        await settle()

        let expected = RecordingRunTerminalState.processingFailure(
            RecordingRunFailure(message: RecordingRun.armingDeadlineFailureMessage)
        )
        #expect(await run.waitForIdle(timeout: .seconds(1)) == expected)
        #expect(adapter.states == [expected])
        // Must not collapse into Empty Result — keyboard wire gets Processing Failure.
        #expect(adapter.states != [.emptyResult])
    }

    @Test("first audio buffer before the deadline leaves the run alive")
    func firstBufferCancelsArmingDeadline() async {
        let clock = TestClock()
        let capture = ControllableRecordingAudioCapture(startResult: true)
        let adapter = SpyCompletionAdapter()
        let run = makeRun(audioRecorder: capture, clock: clock, completionAdapters: [adapter])

        #expect(await run.start() == true)
        await settle()
        #expect(clock.sleepCount == 1)

        capture.deliverSilentBuffer()
        await settle()

        clock.advance()
        await settle()

        #expect(!run.isTerminal)
        #expect(adapter.states.isEmpty)

        _ = await run.cancel()
    }

    @Test("Arming Deadline publishes Processing Failure on the keyboard wire")
    func armingDeadlineReachesKeyboardWire() async {
        let clock = TestClock()
        let capture = ControllableRecordingAudioCapture(startResult: true)
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)
        let keyboardAdapter = KeyboardChannelRecordingRunCompletionAdapter(
            keyboardChannel: channel,
            origin: .keyboard
        )
        let run = makeRun(
            audioRecorder: capture,
            clock: clock,
            completionAdapters: [keyboardAdapter]
        )

        #expect(await run.start() == true)
        await settle()
        #expect(clock.sleepCount == 1)

        clock.advance()
        await settle()

        #expect(
            await run.waitForIdle(timeout: .seconds(1))
                == .processingFailure(
                    RecordingRunFailure(message: RecordingRun.armingDeadlineFailureMessage)
                )
        )
        #expect(channel.readState() == .failed(RecordingRun.armingDeadlineFailureMessage))
    }

    private func makeRun(
        audioRecorder: any RecordingAudioCapturing,
        clock: HotMicClock,
        completionAdapters: [any RecordingRunCompletionAdapter]
    ) -> RecordingRun {
        RecordingRun(
            audioRecorder: audioRecorder,
            streaming: FakeRecordingStreamingSession(),
            transcriptProcessor: TranscriptProcessor(
                makeAIProvider: {
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
            completionAdapters: completionAdapters,
            clock: clock,
            currentSettings: {
                RecordingRun.Settings(
                    promptMode: .verbatim,
                    textStyle: .casual,
                    hasAICapability: false
                )
            },
            onLiveTranscript: { _ in },
            onInterimResult: { _ in },
            onTranscribingMessage: { _ in }
        )
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func success(
        transcript: String = "raw",
        processed: String? = nil,
        finalText: String = "final",
        historyLabel: String? = nil
    ) -> RecordingRunSuccess {
        RecordingRunSuccess(
            conversationID: UUID(),
            transcript: transcript,
            processed: processed,
            finalText: finalText,
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

/// Controllable capture seam: can return success without buffers, hang until
/// `stopCapture`, and deliver a silent first buffer for deadline tests.
@MainActor
private final class ControllableRecordingAudioCapture: RecordingAudioCapturing {
    private let startResult: Bool
    private let hangUntilStopped: Bool
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var hangContinuation: CheckedContinuation<Void, Never>?

    init(startResult: Bool = true, hangUntilStopped: Bool = false) {
        self.startResult = startResult
        self.hangUntilStopped = hangUntilStopped
    }

    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        self.onBuffer = onBuffer
        if hangUntilStopped {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                hangContinuation = cont
            }
        }
        return startResult
    }

    func stopCapture() {
        if let hangContinuation {
            self.hangContinuation = nil
            hangContinuation.resume()
        }
        onBuffer = nil
    }

    func deliverSilentBuffer() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        onBuffer?(buffer)
    }
}
