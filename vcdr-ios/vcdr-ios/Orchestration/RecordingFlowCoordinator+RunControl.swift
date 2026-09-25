import Foundation
import OSLog
import UIKit

/// The one Recording Run in flight, as a single value: which origin started
/// it, the run itself, and its phase.
struct ActiveRecordingRun {
    let origin: RecordingRunOrigin
    let run: RecordingRun
    var phase: RecordingRunPhase
}

/// What a stop did to the active Recording Run.
enum RecordingStopResult: Equatable {
    case cancelledArming
    case finalized(RecordingRunTerminalState)
    case ignored
    case noRun
}

/// Starting, stopping and discarding the active Recording Run. Every trigger
/// (app, keyboard, deep link, Shortcut, card) reaches the run through here,
/// and the run's origin, not the trigger, decides delivery and Captures.
extension RecordingFlowCoordinator {
    private static let finalizingTaskName = "Finalizing"
    private static let stopWithoutRunReason = "Recording was interrupted before audio started"

    var activeRunPhase: RecordingRunPhase? { activeRun?.phase }

    /// Starts recording with real-time streaming transcription.
    /// Audio capture begins immediately; model initialization and streaming setup
    /// proceed in the background. Buffers queue in StreamingAsrManager's AsyncStream
    /// until the recognition task starts consuming them.
    func startRecording(origin: RecordingRunOrigin) async {
        // `recordingEngine.isRecording` rather than `state`: the deep link flow
        // sets `state = .arming` in `prepareForDeepLinkRecording()` before this
        // runs. `activeRun` covers the window before `startCapture` returns,
        // where a second start would stomp the first run's buffer handler.
        guard !recordingEngine.isRecording, activeRun == nil else {
            Logger.app.info("[RecordTiming] startRecording bailed — session already active or starting")
            return
        }
        let recordStart = ContinuousClock.now
        Logger.app.info("[RecordTiming] startRecording entered origin=\(String(describing: origin))")

        // UI flip FIRST — nothing blocks it. Everything perceptually slow
        // (haptics, UserDefaults reads, disk flushes, engine start) runs after.
        launchedViaDeepLink = origin == .keyboard
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        state = .arming
        setIdleTimerDisabled(true)
        Logger.app.info("[RecordTiming] state=arming set at +\(ContinuousClock.now - recordStart)")

        // Session snapshot from shared defaults — only consumed on stop / AI
        // processing, so it runs after the audio start. UserDefaults reads +
        // JSON decode can cost 5-50ms on MainActor under I/O contention.
        capturedTexts = []
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectedPromptMode = SessionSettings.effectiveAIMode()
            self.currentTextStyle = SessionSettings.effectiveTextStyle()
            guard origin.usesKeyboardCaptures else { return }
            let texts = self.keyboardChannel.readCaptures()
            if !texts.isEmpty {
                self.capturedTexts = texts
                Logger.ai.info("Initial captures on start: \(texts.count) item(s)")
            }
            self.keyboardChannel.clearLegacySelectedText()
        }

        // Every origin shows `.recording` to the keyboard, so a keyboard stop
        // can end any run.
        Task.detached { [weak self] in
            await self?.writeStateAsync(.recording)
        }

        // We're about to record: protect any already-alive Hot Mic Session
        // while Arming, without creating fresh Mic Presence for a cold engine.
        hotMicSession.recordIntentStarted()

        let run = makeRecordingRun(origin: origin)
        // Set before the first await, so a stop or a second toggle arriving
        // during Arming already sees this run.
        setActiveRun(ActiveRecordingRun(origin: origin, run: run, phase: .arming))
        Logger.app.info("[RecordTiming] recording run created at +\(ContinuousClock.now - recordStart)")

        let started = await run.start()
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned (Capturing) at +\(ContinuousClock.now - recordStart)")

        // `reset()` or the run's own Processing Failure already let go of it.
        guard let active = activeRun, active.run === run else { return }

        // A failed start still ours was cancelled during Arming: a failure
        // while Arming reaches `handleRecordingRunTerminal` first.
        guard started else {
            hotMicSession.recordIntentCancelledBeforeCapture()
            setActiveRun(nil)
            return
        }

        guard active.phase == .arming else {
            // A stop landed while Arming. The engine is up now, but the user
            // already cancelled, so tear the run down instead of Capturing.
            _ = await run.cancel()
            if activeRun?.run === run { setActiveRun(nil) }
            hotMicSession.recordIntentCancelledBeforeCapture()
            return
        }

        // Capturing: audio is flowing. Skip the "go" haptic while the model is
        // cold so a first-use haptic-daemon connect can't block the main
        // thread under the concurrent ANE compile.
        setActiveRun(ActiveRecordingRun(origin: origin, run: run, phase: .capturing(since: .now)))
        state = .recording
        hotMicSession.recordingStarted()
        if isModelReady { recordHaptic.impactOccurred() }
    }

    /// Stops the active Recording Run: cancels it during Arming, finalizes it
    /// during Capturing, and ignores it once a cancel or a Finalizing is
    /// already in flight.
    @discardableResult
    func stopActiveRun() async -> RecordingStopResult {
        guard let active = activeRun else { return .noRun }
        switch active.phase {
        case .cancellingArming, .finalizing:
            Logger.app.info("[RecordTiming] stop ignored — run is \(String(describing: active.phase))")
            return .ignored
        case .arming:
            // No audio ever flowed. This is a cancellation, not an Empty Result.
            Logger.app.info("[RecordTiming] stop during Arming — cancelling")
            abortArming()
            return .cancelledArming
        case .capturing:
            return .finalized(await finalize(active))
        }
    }

    /// A keyboard stop that finds no run still owes the keyboard a terminal
    /// state: the keyboard is polling for one (ADR-0004).
    func stopFromKeyboard() async {
        guard await stopActiveRun() == .noRun else { return }
        Logger.recording.error("Publishing failure: stop found no Recording Run — \(Self.stopWithoutRunReason)")
        state = .error(Self.stopWithoutRunReason)
        writeFailure(reason: Self.stopWithoutRunReason)
    }

    /// Ends the active Recording Run without producing text (Discard,
    /// ADR-0003). Scoped to Arming and Capturing:
    /// - Arming takes the same path a stop landing mid-Arming takes
    ///   (`abortArming`).
    /// - Capturing cancels the run directly, terminating in `.cancellation`
    ///   (no Bundled Result, no Conversation) while leaving the Hot Mic
    ///   Session warm exactly as a normal stop does.
    /// - Finalizing is ignored: a model load or AI call in flight is not
    ///   abortable.
    func discardRecording() async {
        guard let active = activeRun else { return }
        switch active.phase {
        case .arming:
            Logger.app.info("[RecordTiming] discardRecording during Arming — cancelling")
            clearCapturedTexts(for: active.origin)
            abortArming()
            flashCancelled(revertingTo: .idle)
        case .capturing:
            hotMicSession.recordingStopped()
            setIdleTimerDisabled(false)
            clearCapturedTexts(for: active.origin)

            let terminalState = await active.run.cancel()
            guard activeRun?.run === active.run else { return }
            setActiveRun(nil)
            switch terminalState {
            case .cancellation:
                flashCancelled(revertingTo: .ready)
            default:
                applyTerminalStateToUI(terminalState)
            }
        case .cancellingArming, .finalizing:
            return
        }
    }

    /// Completion Delivery by origin. Every run takes the Keyboard Channel off
    /// `.recording`, and every success reaches history.
    func completionAdapters(for origin: RecordingRunOrigin) -> [any RecordingRunCompletionAdapter] {
        [
            KeyboardChannelRecordingRunCompletionAdapter(keyboardChannel: keyboardChannel, origin: origin),
            historyCompletionAdapter
        ]
    }

    private func finalize(_ active: ActiveRecordingRun) async -> RecordingRunTerminalState {
        if isModelReady { recordHaptic.impactOccurred() }
        hotMicSession.recordingStopped()
        setIdleTimerDisabled(false)

        // The keyboard may have added Captures while the run was Capturing.
        if active.origin.usesKeyboardCaptures {
            let texts = keyboardChannel.readCaptures()
            if !texts.isEmpty {
                capturedTexts = texts
                Logger.ai.info("Final captures on stop: \(texts.count) item(s)")
            }
            keyboardChannel.clearCaptures()
        }

        setActiveRun(ActiveRecordingRun(origin: active.origin, run: active.run, phase: .finalizing))
        state = .transcribing
        writeState(.transcribing)

        let terminalState = await backgroundTasks.run(named: Self.finalizingTaskName) {
            await active.run.stop()
        }
        guard activeRun?.run === active.run else { return terminalState }
        applyTerminalStateToUI(terminalState)
        setActiveRun(nil)
        return terminalState
    }
}
