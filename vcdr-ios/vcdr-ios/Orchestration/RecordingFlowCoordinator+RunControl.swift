import Foundation
import OSLog
import UIKit

struct ActiveRecordingRun {
    let origin: RecordingRunOrigin
    let run: RecordingRun
    /// Clipboard Delivery for an origin that delivers there. The card reports
    /// whether the copy took effect, so the coordinator keeps the destination.
    let clipboard: ClipboardRecordingRunCompletionAdapter?
    var phase: RecordingRunPhase
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

    func startRecording(origin: RecordingRunOrigin) async {
        guard !recordingEngine.isRecording, activeRun == nil else {
            Logger.app.info("[RecordTiming] startRecording bailed — session already active or starting")
            return
        }
        let recordStart = ContinuousClock.now
        Logger.app.info("[RecordTiming] startRecording entered origin=\(String(describing: origin))")

        isKeyboardRun = origin == .keyboard
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        state = .arming
        setIdleTimerDisabled(true)
        Logger.app.info("[RecordTiming] state=arming set at +\(ContinuousClock.now - recordStart)")

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

        Task.detached { [weak self] in
            await self?.writeStateAsync(.recording)
        }

        hotMicSession.recordIntentStarted()

        let clipboard = origin.deliversToClipboard ? ClipboardRecordingRunCompletionAdapter(pasteboard: pasteboard) : nil
        let run = makeRecordingRun(origin: origin, clipboard: clipboard)
        setActiveRun(ActiveRecordingRun(origin: origin, run: run, clipboard: clipboard, phase: .arming))
        Logger.app.info("[RecordTiming] recording run created at +\(ContinuousClock.now - recordStart)")

        let started = await run.start()
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned (Capturing) at +\(ContinuousClock.now - recordStart)")

        guard let active = activeRun, active.run === run else { return }

        guard started else {
            hotMicSession.recordIntentCancelledBeforeCapture()
            setActiveRun(nil)
            return
        }

        guard active.phase == .arming else {
            _ = await run.cancel()
            if activeRun?.run === run { setActiveRun(nil) }
            hotMicSession.recordIntentCancelledBeforeCapture()
            return
        }

        setActiveRun(ActiveRecordingRun(origin: origin, run: run, clipboard: clipboard, phase: .capturing(since: .now)))
        state = .recording
        hotMicSession.recordingStarted()
        if isModelReady { recordHaptic.impactOccurred() }
    }

    @discardableResult
    func stopActiveRun() async -> RecordingStopResult {
        guard let active = activeRun else { return .noRun }
        switch active.phase {
        case .cancellingArming, .finalizing:
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

    func discardRecording() async {
        guard let active = activeRun else { return }
        switch active.phase {
        case .arming:
            Logger.app.info("[RecordTiming] discardRecording during Arming — cancelling")
            clearCapturedTexts(for: active.origin)
            abortArming()
            flashCancelled(revertingTo: .idle)
        case .capturing:
            active.run.endCapture()
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

    func completionAdapters(
        for origin: RecordingRunOrigin,
        clipboard: ClipboardRecordingRunCompletionAdapter?
    ) -> [any RecordingRunCompletionAdapter] {
        let keyboard = KeyboardChannelRecordingRunCompletionAdapter(keyboardChannel: keyboardChannel, origin: origin)
        let adapters: [(any RecordingRunCompletionAdapter)?] = [clipboard, keyboard, historyCompletionAdapter]
        return adapters.compactMap { $0 }
    }

    private func finalize(_ active: ActiveRecordingRun) async -> RecordingRunTerminalState {
        if isModelReady { recordHaptic.impactOccurred() }
        active.run.endCapture()
        hotMicSession.recordingStopped()
        setIdleTimerDisabled(false)

        if active.origin.usesKeyboardCaptures {
            let texts = keyboardChannel.readCaptures()
            if !texts.isEmpty {
                capturedTexts = texts
                Logger.ai.info("Final captures on stop: \(texts.count) item(s)")
            }
            keyboardChannel.clearCaptures()
        }

        var finalizing = active
        finalizing.phase = .finalizing
        setActiveRun(finalizing)
        state = .transcribing
        writeState(.transcribing)

        let terminalState = await backgroundTasks.run(named: Self.finalizingTaskName) {
            await active.run.stop()
        }
        guard activeRun?.run === active.run else { return terminalState }
        applyTerminalStateToUI(terminalState)
        endActiveRun(announcing: RunCardOutcome(terminalState, clipboard: active.clipboard))
        return terminalState
    }
}

extension RunCardOutcome {
    init?(_ terminal: RecordingRunTerminalState, clipboard: ClipboardRecordingRunCompletionAdapter?) {
        guard let clipboard else { return nil }
        switch terminal {
        case .success: self = clipboard.copied ? .copied : .failed
        case .emptyResult: self = .noSpeech
        case .processingFailure: self = .failed
        case .cancellation: return nil
        }
    }
}
