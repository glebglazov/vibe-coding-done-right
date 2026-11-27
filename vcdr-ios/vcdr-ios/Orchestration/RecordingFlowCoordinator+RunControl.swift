import Foundation
import OSLog
import UIKit

/// The current Recording Run. Its phase is read from the run, never kept here.
struct ActiveRecordingRun {
    let origin: RecordingRunOrigin
    let run: RecordingRun
}

enum RecordingStartResult: Equatable {
    case capturing
    case cancelledArming
    case failed(String)
    case ignored
}

enum RecordingStopResult: Equatable {
    case cancelledArming
    case finalized(RecordingRunTerminalState)
    case ignored
    case noRun
}

extension RecordingFlowCoordinator {
    private static let finalizingTaskName = "Finalizing"
    private static let stopWithoutRunReason = "Recording was interrupted before audio started"

    var activeRunPhase: RecordingRunPhase? { activeRun?.run.phase.live }

    var hasMicrophonePermission: Bool { recordingEngine.hasMicrophonePermission }

    @discardableResult
    func startRecording(origin: RecordingRunOrigin) async -> RecordingStartResult {
        guard let run = beginRecording(origin: origin) else { return .ignored }
        return await armUntilCapturing(run)
    }

    /// Makes a new run current, Arming, with no await: from the next line on,
    /// a stop or a second start sees it. Nil while another run is current.
    func beginRecording(origin: RecordingRunOrigin) -> RecordingRun? {
        guard !recordingEngine.isRecording, activeRun == nil else {
            Logger.app.info("[RecordTiming] startRecording bailed — session already active or starting")
            return nil
        }
        Logger.app.info("[RecordTiming] startRecording entered origin=\(String(describing: origin))")

        isKeyboardRun = origin == .keyboard
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        discardNotes.dismiss()
        state = .arming
        setIdleTimerDisabled(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectedPromptMode = SettingOverrides.effectiveAIMode()
            self.currentTextStyle = SettingOverrides.effectiveTextStyle()
        }

        hotMicSession.recordIntentStarted()

        let run = makeRecordingRun(origin: origin)
        activeRun = ActiveRecordingRun(origin: origin, run: run)
        runPresence.runChanged(.active(origin: origin, phase: .arming))
        return run
    }

    /// Arming, until audio flows or the run ends. Only a failure has a
    /// message the caller can show.
    func armUntilCapturing(_ run: RecordingRun) async -> RecordingStartResult {
        let armingStart = ContinuousClock.now
        let started = await run.start()
        Logger.app.info("[RecordTiming] Arming ended (capturing=\(started)) after \(ContinuousClock.now - armingStart)")
        if started { return .capturing }
        if case .processingFailure(let failure)? = run.terminalState { return .failed(failure.message) }
        return .cancelledArming
    }

    @discardableResult
    func stopActiveRun() async -> RecordingStopResult {
        guard let active = activeRun else { return .noRun }
        return await stop(active)
    }

    func stopFromKeyboard() async {
        guard await stopActiveRun() == .noRun else { return }
        Logger.recording.error("Publishing failure: stop found no Recording Run — \(Self.stopWithoutRunReason)")
        state = .error(Self.stopWithoutRunReason)
        writeFailure(reason: Self.stopWithoutRunReason)
    }

    /// An interruption or a failed route restart cut the capture. A Capturing
    /// run ends as if the user stopped it, so the words captured so far are
    /// transcribed. A run still Arming holds no lease yet: its `startCapture`
    /// returns none, and the run ends in a Processing Failure on its own.
    func captureLost(_ loss: EngineLoss) async {
        guard let lease = loss.lease, let active = activeRun, active.run.id == lease.run,
              case .capturing = active.run.phase else { return }
        Logger.recording.warning("Capture lost (\(loss.reason)) — stopping the run")
        _ = await stop(active)
    }

    func completionAdapters(for origin: RecordingRunOrigin) -> [any RecordingRunCompletionAdapter] {
        [KeyboardChannelRecordingRunCompletionAdapter(keyboardChannel: keyboardChannel, origin: origin), historyCompletionAdapter]
    }

    private func stop(_ active: ActiveRecordingRun) async -> RecordingStopResult {
        switch active.run.phase {
        case .arming:
            Logger.app.info("[RecordTiming] stop during Arming — cancelling")
            _ = await active.run.cancel()
            return .cancelledArming
        case .capturing:
            if isModelReady { recordHaptic.impactOccurred() }
            await active.run.endCapture()
            return .finalized(await backgroundTasks.run(named: Self.finalizingTaskName) {
                let terminalState = await active.run.stop()
                await runPresence.settled()
                return terminalState
            })
        case .finalizing, .ended:
            Logger.app.info("[RecordTiming] stop ignored — run is \(String(describing: active.run.phase))")
            return .ignored
        }
    }

    /// The one place the coordinator hears a run move. A run that is not the
    /// current one changes nothing here.
    func recordingRun(_ run: RecordingRun, movedFrom previous: RecordingRun.Phase) {
        guard let active = activeRun, active.run === run else { return }
        switch run.phase {
        case .arming:
            return
        case .capturing(let since):
            runPresence.runChanged(.active(origin: active.origin, phase: .capturing(since: since)))
            state = .recording
            hotMicSession.recordingStarted()
            if isModelReady { recordHaptic.impactOccurred() }
        case .finalizing:
            // The Hot Mic Session hears of the stop once the engine is idle,
            // before Finalizing begins.
            hotMicSession.recordingStopped()
            setIdleTimerDisabled(false)
            runPresence.runChanged(.active(origin: active.origin, phase: .finalizing))
            state = .transcribing
        case .ended(let terminal):
            activeRun = nil
            let until = Date.now.addingTimeInterval(MicPresenceCardPolicy.concludedDwell)
            runPresence.runChanged(RunCardOutcome(terminal, origin: active.origin).map { .concluded($0, until: until) })
            switch previous {
            case .arming: hotMicSession.recordIntentCancelledBeforeCapture()
            case .capturing: hotMicSession.recordingStopped()
            case .finalizing, .ended: break
            }
            setIdleTimerDisabled(false)
            showOutcome(terminal, endedWhileArming: previous == .arming)
        }
    }

    /// A run cancelled before audio flowed goes back to the readiness it
    /// covered, so a model download in progress shows again.
    private func showOutcome(_ terminal: RecordingRunTerminalState, endedWhileArming: Bool) {
        switch terminal {
        case .success(let success):
            state = .complete(success.finalText)
        case .emptyResult:
            // Same constant the status row recognises, so the empty-result
            // wording can't drift between the two.
            state = .error(TransientStatus.noSpeechDetectedText)
        case .cancellation:
            state = endedWhileArming ? readinessState : .ready
        case .processingFailure(let failure):
            state = .error(failure.message)
        }
    }
}

extension RunCardOutcome {
    init?(_ terminal: RecordingRunTerminalState, origin: RecordingRunOrigin) {
        guard origin.showsOutcomeOnCard else { return nil }
        switch terminal {
        case .success: self = .transcribed
        case .emptyResult: self = .noSpeech
        case .processingFailure: self = .failed
        case .cancellation: return nil
        }
    }
}
