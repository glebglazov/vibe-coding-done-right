import AVFoundation
import FluidAudio
import Foundation
import OSLog

@MainActor
protocol RecordingAudioCapturing: AnyObject {
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool
    func stopCapture()
}

extension AudioRecorder: RecordingAudioCapturing {}

protocol RecordingStreamingSession: Sendable {
    /// Prepares the model this session runs and begins consuming the buffers
    /// captured so far. The session already knows its provider — it was made by
    /// one (`docs/adr/0022`).
    func start() async throws
    /// Synchronous + ordered: callers feed buffers FIFO from the audio thread.
    /// Implementations must not block.
    func streamAudio(_ buffer: AVAudioPCMBuffer)
    func cancel() async
    func finish() async throws -> String
    func liveTranscriptUpdates() async -> AsyncStream<String>
}

@MainActor
final class RecordingRun {
    typealias Settings = TranscriptProcessor.Settings

    private let conversationID = UUID()
    let audioRecorder: any RecordingAudioCapturing
    let streaming: any RecordingStreamingSession
    private let transcriptProcessor: TranscriptProcessor
    private let completionAdapters: [any RecordingRunCompletionAdapter]
    let clock: HotMicClock
    private let currentSettings: @MainActor () -> Settings
    private let currentCaptures: @MainActor () -> [String]
    private let currentSubstitutions: @MainActor () -> [Substitution]
    private let onLiveTranscript: @MainActor (String) -> Void
    private let onInterimResult: @MainActor (String) -> Void
    private let onTranscribingMessage: @MainActor (String) -> Void
    private let onTerminal: @MainActor (RecordingRunTerminalState) -> Void

    private var setupTask: Task<Void, Error>?
    private var updateTask: Task<Void, Never>?
    var armingDeadlineTask: Task<Void, Never>?
    private var terminalState: RecordingRunTerminalState?
    private var latestLiveTranscript = ""
    var hasReceivedFirstAudioBuffer = false

    init(
        audioRecorder: any RecordingAudioCapturing,
        streaming: any RecordingStreamingSession,
        transcriptProcessor: TranscriptProcessor,
        completionAdapters: [any RecordingRunCompletionAdapter],
        clock: HotMicClock? = nil,
        currentSettings: @escaping @MainActor () -> Settings,
        currentCaptures: @escaping @MainActor () -> [String],
        currentSubstitutions: @escaping @MainActor () -> [Substitution] = { [] },
        onLiveTranscript: @escaping @MainActor (String) -> Void,
        onInterimResult: @escaping @MainActor (String) -> Void,
        onTranscribingMessage: @escaping @MainActor (String) -> Void,
        onTerminal: @escaping @MainActor (RecordingRunTerminalState) -> Void = { _ in }
    ) {
        self.audioRecorder = audioRecorder
        self.streaming = streaming
        self.transcriptProcessor = transcriptProcessor
        self.completionAdapters = completionAdapters
        // Optional so the default can be built inside this `@MainActor` init —
        // default-argument expressions evaluate in a nonisolated context.
        self.clock = clock ?? SystemHotMicClock()
        self.currentSettings = currentSettings
        self.currentCaptures = currentCaptures
        self.currentSubstitutions = currentSubstitutions
        self.onLiveTranscript = onLiveTranscript
        self.onInterimResult = onInterimResult
        self.onTranscribingMessage = onTranscribingMessage
        self.onTerminal = onTerminal
    }

    var isTerminal: Bool { terminalState != nil }

    func start() async -> Bool {
        setupTask = Task.detached { [streaming] in
            try await streaming.start()
        }

        latestLiveTranscript = ""
        onLiveTranscript("")
        updateTask = startConsumingUpdates()
        // Arming Deadline (ADR-0005): keyed on the first audio buffer, not on
        // `startCapture` returning — a hung engine start must still fail honest.
        startArmingDeadline()

        let started = await audioRecorder.startCapture { [streaming] buffer in
            Task { @MainActor [weak self] in
                self?.noteFirstAudioBuffer()
            }
            streaming.streamAudio(buffer)
        }

        if isTerminal {
            return false
        }

        if !started {
            cancelArmingDeadline()
            cancelSetup()
            _ = await finish(.processingFailure(
                RecordingRunFailure(message: "Failed to start recording — check microphone permission")
            ))
            return false
        }
        return true
    }

    func stop() async -> RecordingRunTerminalState {
        guard terminalState == nil else {
            return terminalState ?? .cancellation
        }

        cancelArmingDeadline()
        audioRecorder.stopCapture()
        updateTask?.cancel()

        let waitStart = ContinuousClock.now
        onTranscribingMessage("Loading model — your recording is safe")
        let elapsedTicker = makeElapsedTicker(waitStart: waitStart)

        do {
            try await setupTask?.value
        } catch {
            elapsedTicker.cancel()
            await streaming.cancel()
            return await finish(.processingFailure(
                RecordingRunFailure(message: "Transcription unavailable: \(error.localizedDescription)")
            ))
        }
        elapsedTicker.cancel()
        onTranscribingMessage("")

        let cleanedLive = TextPostProcessor.removeFillers(from: latestLiveTranscript)
        onLiveTranscript("")

        let interimSettings = currentSettings()
        if let interimText = transcriptProcessor.interimText(for: cleanedLive, settings: interimSettings) {
            onInterimResult(interimText)
        } else {
            let usesAI = interimSettings.promptMode != .verbatim && interimSettings.hasAICapability
            onTranscribingMessage(usesAI ? "Enhancing with AI..." : "")
        }

        do {
            return try await finishStreaming()
        } catch {
            return await finish(.processingFailure(
                RecordingRunFailure(message: "Transcription failed: \(error.localizedDescription)")
            ))
        }
    }

    func cancel() async -> RecordingRunTerminalState {
        cancelArmingDeadline()
        audioRecorder.stopCapture()
        cancelSetup()
        await streaming.cancel()
        return await finish(.cancellation)
    }

    /// DEBUG / test-only: polls until this run reaches its terminal resting
    /// state and returns the recorded outcome. Production code never reads it.
    func waitForIdle(timeout: Duration = .seconds(10)) async -> RecordingRunTerminalState? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if let terminalState {
                return terminalState
            }
            try? await Task.sleep(for: Self.idlePollInterval)
        }
        return nil
    }

    private func finishStreaming() async throws -> RecordingRunTerminalState {
        let rawText = try await streaming.finish()
        // Substitution — first pre-processing step, before filler removal, on
        // the dictated transcript only, in every AI Prompt Mode (Verbatim
        // included). Captures are never run through the matcher. The keyboard
        // extension stays out of this: it receives the already-substituted
        // text via the Bundled Result on the Keyboard Channel.
        let substitutedText = SubstitutionMatcher(substitutions: currentSubstitutions())
            .apply(to: rawText)
        if substitutedText != rawText {
            Logger.app.info("After substitutions: \(substitutedText.prefix(50))...")
        }
        let cleanedText = TextPostProcessor.removeFillers(from: substitutedText)
        Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

        guard !cleanedText.isEmpty else {
            return await finish(.emptyResult)
        }

        let captures = currentCaptures()
        let output = await transcriptProcessor.processFinalTranscript(
            cleanedText,
            initialSettings: currentSettings(),
            finalSettings: currentSettings,
            captures: captures
        )
        let terminal = RecordingRunTerminalState.success(RecordingRunSuccess(
            conversationID: conversationID,
            transcript: output.transcript,
            processed: output.processed,
            finalText: output.finalText,
            captures: captures,
            historyLabel: output.historyLabel
        ))
        return await finish(terminal)
    }

    func finish(_ terminal: RecordingRunTerminalState) async -> RecordingRunTerminalState {
        cancelArmingDeadline()
        terminalState = terminal
        logTerminal(terminal)
        onTranscribingMessage("")
        for adapter in completionAdapters {
            await adapter.complete(terminal)
        }
        onTerminal(terminal)
        return terminal
    }

    /// Every terminal branch — mic seizure, model-load throw, finalization
    /// throw, Empty Result, cancellation, success — funnels through `finish`,
    /// so logging here is what makes "which of the four states did this run
    /// reach" answerable from a field report's log (ADR-0004). A Processing
    /// Failure carries the same reason string the user is shown, at error
    /// level; the other states are ordinary lifecycle facts at info.
    private func logTerminal(_ terminal: RecordingRunTerminalState) {
        switch terminal {
        case .processingFailure(let failure):
            Logger.recording.error("Run terminal state: \(terminal.logName) — \(failure.message)")
        case .success(let success):
            Logger.recording.info(
                "Run terminal state: \(terminal.logName) (\(success.finalText.count) chars)"
            )
        case .emptyResult, .cancellation:
            Logger.recording.info("Run terminal state: \(terminal.logName)")
        }
    }

    func cancelSetup() {
        updateTask?.cancel()
        setupTask?.cancel()
    }

    private func makeElapsedTicker(waitStart: ContinuousClock.Instant) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let elapsed = Int((ContinuousClock.now - waitStart).components.seconds)
                self.onTranscribingMessage("Loading model · \(elapsed)s — your recording is safe")
            }
        }
    }

    private func startConsumingUpdates() -> Task<Void, Never> {
        Task {
            let updates = await streaming.liveTranscriptUpdates()
            var lastUpdateTime: ContinuousClock.Instant = .now
            for await text in updates {
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                guard now - lastUpdateTime >= Self.transcriptUpdateInterval else { continue }
                lastUpdateTime = now

                latestLiveTranscript = text
                onLiveTranscript(text)
            }
        }
    }

    private static let idlePollInterval: Duration = .milliseconds(20)
    private static let transcriptUpdateInterval: Duration = .milliseconds(16)
}
