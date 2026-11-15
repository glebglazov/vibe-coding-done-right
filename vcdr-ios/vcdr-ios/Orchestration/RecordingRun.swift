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

    let conversationID = UUID()
    let audioRecorder: any RecordingAudioCapturing
    let streaming: any RecordingStreamingSession
    private let transcriptProcessor: TranscriptProcessor
    private let completionAdapters: [any RecordingRunCompletionAdapter]
    let clock: HotMicClock
    /// A discarded run that is still decoding. Transcription setup waits for
    /// it, so two decodes never run at once (ADR-0010). The audio captured
    /// meanwhile waits in the streaming session, as it does for a model load.
    private let decodeInFlight: Task<Void, Never>?
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
    private(set) var terminalState: RecordingRunTerminalState?
    private var captureEnded = false
    private var latestLiveTranscript = ""
    var hasReceivedFirstAudioBuffer = false

    init(
        audioRecorder: any RecordingAudioCapturing,
        streaming: any RecordingStreamingSession,
        transcriptProcessor: TranscriptProcessor,
        completionAdapters: [any RecordingRunCompletionAdapter],
        clock: HotMicClock? = nil,
        decodeInFlight: Task<Void, Never>? = nil,
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
        self.decodeInFlight = decodeInFlight
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
        setupTask = Task.detached { [streaming, decodeInFlight] in
            await decodeInFlight?.value
            try Task.checkCancellation()
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

    /// Ends Capturing on its own so the caller can tell the Hot Mic Session
    /// of the stop once the engine is really idle, before Finalizing begins.
    func endCapture() {
        guard !captureEnded else { return }
        captureEnded = true
        cancelArmingDeadline()
        updateTask?.cancel()
        audioRecorder.stopCapture()
    }

    func stop() async -> RecordingRunTerminalState {
        guard terminalState == nil else {
            return terminalState ?? .cancellation
        }

        endCapture()

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
        endCapture()
        cancelSetup()
        await streaming.cancel()
        return await finish(.cancellation)
    }

    /// Ends a discarded run and returns its verbatim transcript: the raw text
    /// of the streaming session, with no Substitutions, no filler removal and
    /// no AI. Empty when nothing was said or the transcription failed.
    ///
    /// No completion adapter and no callback hears of this ending. The
    /// keyboard already has `cancelled`, and by now a later run can own the
    /// wire and the screen.
    func finishDiscarded() async -> String {
        guard terminalState == nil else { return "" }
        endCapture()
        defer {
            terminalState = .cancellation
            Logger.recording.info("Run terminal state: discarded")
        }
        do {
            try await setupTask?.value
            return try await streaming.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await streaming.cancel()
            Logger.recording.error("Discarded run was not transcribed: \(error)")
            return ""
        }
    }

    private func finishStreaming() async throws -> RecordingRunTerminalState {
        let rawText = try await streaming.finish()
        // Substitution — first pre-processing step, before filler removal, on
        // the dictated transcript only, in every AI Prompt Mode (Verbatim
        // included). Captures are never run through the matcher. The keyboard
        // extension stays out of this: it receives the already-substituted
        // text via the Bundled Result on the Keyboard Channel.
        let dictionary = currentSubstitutions()
        let substitutedText = SubstitutionMatcher(substitutions: dictionary)
            .apply(to: rawText)
        if substitutedText != rawText {
            Logger.app.info("After substitutions: \(substitutedText.prefix(50))...")
        }
        let cleanedText = TextPostProcessor.removeFillers(from: substitutedText)
        Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

        guard !cleanedText.isEmpty else {
            return await finish(.emptyResult)
        }

        let initialSettings = currentSettings()
        let captures = initialSettings.promptMode.usesCaptures ? currentCaptures() : []
        let output = await transcriptProcessor.processFinalTranscript(
            cleanedText,
            initialSettings: initialSettings,
            finalSettings: currentSettings,
            captures: captures,
            spellingHints: SpellingHints(dictionary)
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

    private static let transcriptUpdateInterval: Duration = .milliseconds(16)
}
