import AVFoundation
import FluidAudio
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class RecordingRun {
    typealias Settings = TranscriptProcessor.Settings

    let id = RunID()
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
    private let currentSubstitutions: @MainActor () -> [Substitution]
    private let onLiveTranscript: @MainActor (String) -> Void
    private let onInterimResult: @MainActor (String) -> Void
    private let onTranscribingMessage: @MainActor (String) -> Void
    private let onPhaseChange: @MainActor (_ run: RecordingRun, _ previous: Phase) -> Void

    /// Written only by `enter(_:)`.
    private(set) var phase: Phase = .arming
    @ObservationIgnored private(set) var setupTask: Task<Void, Error>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored var armingDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var latestLiveTranscript = ""
    @ObservationIgnored var hasReceivedFirstAudioBuffer = false

    init(
        audioRecorder: any RecordingAudioCapturing,
        streaming: any RecordingStreamingSession,
        transcriptProcessor: TranscriptProcessor,
        completionAdapters: [any RecordingRunCompletionAdapter],
        clock: HotMicClock? = nil,
        decodeInFlight: Task<Void, Never>? = nil,
        currentSettings: @escaping @MainActor () -> Settings,
        currentSubstitutions: @escaping @MainActor () -> [Substitution] = { [] },
        onLiveTranscript: @escaping @MainActor (String) -> Void,
        onInterimResult: @escaping @MainActor (String) -> Void,
        onTranscribingMessage: @escaping @MainActor (String) -> Void,
        onPhaseChange: @escaping @MainActor (_ run: RecordingRun, _ previous: Phase) -> Void = { _, _ in }
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
        self.currentSubstitutions = currentSubstitutions
        self.onLiveTranscript = onLiveTranscript
        self.onInterimResult = onInterimResult
        self.onTranscribingMessage = onTranscribingMessage
        self.onPhaseChange = onPhaseChange
    }

    var terminalState: RecordingRunTerminalState? {
        guard case .ended(let terminal) = phase else { return nil }
        return terminal
    }

    var isTerminal: Bool { terminalState != nil }

    /// Arming until the first capture opens. False when the run ended first:
    /// stopped, cancelled, past its Arming Deadline, or refused by the engine.
    func start() async -> Bool {
        guard case .arming = phase, setupTask == nil else { return false }
        announce(.arming)
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

        let lease = await audioRecorder.startCapture(for: id) { [streaming] buffer in
            Task { @MainActor [weak self] in
                self?.noteFirstAudioBuffer()
            }
            streaming.streamAudio(buffer)
        }

        guard case .arming = phase else {
            // Ended while the engine started; its claim is already revoked.
            audioRecorder.stopCapture(for: id)
            return false
        }
        guard lease != nil else {
            cancelSetup()
            await finish(.processingFailure(
                RecordingRunFailure(message: "Failed to start recording — check microphone permission")
            ))
            return false
        }
        await enter(.capturing(since: .now))
        return true
    }

    /// Ends Capturing and begins Finalizing, at once, so a second stop sees
    /// Finalizing. `stop()` then transcribes.
    func endCapture() async {
        guard case .capturing = phase else { return }
        await enter(.finalizing)
    }

    /// From Arming, the run is cancelled: nothing was captured. From
    /// Capturing or Finalizing, it transcribes what was captured.
    func stop() async -> RecordingRunTerminalState {
        switch phase {
        case .arming: return await cancel()
        case .capturing: await endCapture()
        case .finalizing: break
        case .ended(let terminal): return terminal
        }

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

    /// Ends the run as cancelled before any await, so a late engine start or
    /// Arming Deadline finds it ended, then tears the transcription down.
    func cancel() async -> RecordingRunTerminalState {
        if let terminalState { return terminalState }
        cancelSetup()
        let terminal = await finish(.cancellation)
        await streaming.cancel()
        return terminal
    }

    private func finishStreaming() async throws -> RecordingRunTerminalState {
        let rawText = try await streaming.finish()
        // Substitution — first pre-processing step, before filler removal, on
        // the dictated transcript only, in every AI Prompt Mode (Verbatim
        // included). The keyboard extension stays out of this: it receives the already-substituted
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

        let output = await transcriptProcessor.processFinalTranscript(
            cleanedText,
            initialSettings: currentSettings(),
            finalSettings: currentSettings,
            spellingHints: SpellingHints(dictionary)
        )
        let terminal = RecordingRunTerminalState.success(RecordingRunSuccess(
            conversationID: conversationID,
            transcript: output.transcript,
            processed: output.processed,
            finalText: output.finalText,
            historyLabel: output.historyLabel
        ))
        return await finish(terminal)
    }

    /// Ends the run. Idempotent: the first terminal state wins, and a later
    /// call returns it without telling anyone again.
    @discardableResult
    func finish(_ terminal: RecordingRunTerminalState) async -> RecordingRunTerminalState {
        await enter(.ended(terminal))
        return terminalState ?? terminal
    }

    /// The only writer of `phase`. The new phase is set before the first
    /// await, so whatever runs next on the main actor already sees it. The
    /// adapters hear of the change before the coordinator does: a run's
    /// outcome is on the wire before it stops being the current run.
    private func enter(_ next: Phase) async {
        guard !isTerminal else { return }
        let previous = phase
        phase = next
        switch next {
        case .arming, .capturing:
            break
        case .finalizing:
            releaseCapture()
        case .ended(let terminal):
            releaseCapture()
            logTerminal(terminal)
            onTranscribingMessage("")
            for adapter in completionAdapters {
                await adapter.complete(terminal)
            }
        }
        if let live = next.live { announce(live) }
        onPhaseChange(self, previous)
    }

    private func announce(_ phase: RecordingRunPhase) {
        for adapter in completionAdapters {
            adapter.progressed(to: phase)
        }
    }

    /// Stops the capture, or revokes the claim of one still starting, so no
    /// buffer and no lease reaches a run that has left Capturing.
    private func releaseCapture() {
        cancelArmingDeadline()
        updateTask?.cancel()
        audioRecorder.stopCapture(for: id)
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
