import Foundation
import OSLog
import UIKit

struct ActiveRecordingRun {
    let origin: RecordingRunOrigin
    let run: RecordingRun
    var phase: RecordingRunPhase
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

    var activeRunPhase: RecordingRunPhase? { activeRun?.phase }

    var hasMicrophonePermission: Bool { recordingEngine.hasMicrophonePermission }

    @discardableResult
    func startRecording(origin: RecordingRunOrigin) async -> RecordingStartResult {
        guard !recordingEngine.isRecording, activeRun == nil else {
            Logger.app.info("[RecordTiming] startRecording bailed — session already active or starting")
            return .ignored
        }
        let recordStart = ContinuousClock.now
        Logger.app.info("[RecordTiming] startRecording entered origin=\(String(describing: origin))")

        isKeyboardRun = origin == .keyboard
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        discardNotes.dismiss()
        state = .arming
        setIdleTimerDisabled(true)
        Logger.app.info("[RecordTiming] state=arming set at +\(ContinuousClock.now - recordStart)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectedPromptMode = SettingOverrides.effectiveAIMode()
            self.currentTextStyle = SettingOverrides.effectiveTextStyle()
        }

        Task.detached { [weak self] in
            await self?.writeStateAsync(.recording)
        }

        hotMicSession.recordIntentStarted()

        let run = makeRecordingRun(origin: origin)
        setActiveRun(ActiveRecordingRun(origin: origin, run: run, phase: .arming))
        Logger.app.info("[RecordTiming] recording run created at +\(ContinuousClock.now - recordStart)")

        let started = await run.start()
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned (Capturing) at +\(ContinuousClock.now - recordStart)")

        guard let active = activeRun, active.run === run else { return Self.endedBeforeCapturing(run) }

        guard started else {
            hotMicSession.recordIntentCancelledBeforeCapture()
            setActiveRun(nil)
            return Self.endedBeforeCapturing(run)
        }

        guard active.phase == .arming else {
            _ = await run.cancel()
            if activeRun?.run === run { setActiveRun(nil) }
            hotMicSession.recordIntentCancelledBeforeCapture()
            return .cancelledArming
        }

        setActiveRun(ActiveRecordingRun(origin: origin, run: run, phase: .capturing(since: .now)))
        state = .recording
        hotMicSession.recordingStarted()
        if isModelReady { recordHaptic.impactOccurred() }
        return .capturing
    }

    /// A run that ended while Arming was either cancelled by the user or
    /// failed to process; only the failure has a message the caller can show.
    private static func endedBeforeCapturing(_ run: RecordingRun) -> RecordingStartResult {
        if case .processingFailure(let failure)? = run.terminalState { return .failed(failure.message) }
        return .cancelledArming
    }

    @discardableResult
    func stopActiveRun() async -> RecordingStopResult {
        guard let active = activeRun else { return .noRun }
        switch active.phase {
        case .cancelling, .finalizing:
            Logger.app.info("[RecordTiming] stop ignored — run is \(String(describing: active.phase))")
            return .ignored
        case .arming:
            Logger.app.info("[RecordTiming] stop during Arming — cancelling")
            abortArming()
            return .cancelledArming
        case .capturing:
            return .finalized(await finalize(active))
        }
    }

    func stopFromKeyboard() async {
        guard await stopActiveRun() == .noRun else { return }
        Logger.recording.error("Publishing failure: stop found no Recording Run — \(Self.stopWithoutRunReason)")
        state = .error(Self.stopWithoutRunReason)
        writeFailure(reason: Self.stopWithoutRunReason)
    }

    func completionAdapters(for origin: RecordingRunOrigin) -> [any RecordingRunCompletionAdapter] {
        [KeyboardChannelRecordingRunCompletionAdapter(keyboardChannel: keyboardChannel, origin: origin), historyCompletionAdapter]
    }

    private func finalize(_ active: ActiveRecordingRun) async -> RecordingRunTerminalState {
        if isModelReady { recordHaptic.impactOccurred() }
        endCapture(of: active)
        return await transcribe(active)
    }

    /// Capture ends once per run, whether a stop or a Discard ends it: the Hot
    /// Mic Session is told when the engine is really idle.
    func endCapture(of active: ActiveRecordingRun) {
        active.run.endCapture()
        hotMicSession.recordingStopped()
        setIdleTimerDisabled(false)
    }

    /// Finalizing, from a run whose capture has already ended.
    func transcribe(_ active: ActiveRecordingRun) async -> RecordingRunTerminalState {
        var finalizing = active
        finalizing.phase = .finalizing
        setActiveRun(finalizing)
        state = .transcribing
        writeState(.transcribing)

        return await backgroundTasks.run(named: Self.finalizingTaskName) {
            let terminalState = await active.run.stop()
            guard activeRun?.run === active.run else { return terminalState }
            applyTerminalStateToUI(terminalState)
            endActiveRun(announcing: RunCardOutcome(terminalState, origin: active.origin))
            await runPresence.settled()
            return terminalState
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
