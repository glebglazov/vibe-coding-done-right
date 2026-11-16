import Foundation
import OSLog

/// Discard (ADR-0010): the run ends at once and never blocks the next run.
/// The words of a run discarded during Capturing go to History.
extension RecordingFlowCoordinator {
    /// The user's Discard. During Arming no audio exists, so nothing is saved.
    /// During Capturing the run leaves the active-run slot at once, and the
    /// Discarded Run Finalizer saves its verbatim transcript in the background.
    func discardRecording() async {
        guard let active = activeRun else { return }
        switch active.phase {
        case .arming:
            Logger.app.info("[RecordTiming] discardRecording during Arming — nothing to save")
            cancelArming(active)
            discardNotes.show(.nothingSaved)
        case .capturing:
            discardCapturing(active)
        case .cancelling, .finalizing:
            return
        }
    }

    /// Ends the run with no result, for a caller that is not the user: a
    /// Shortcut start whose card the system refused. No speech was captured
    /// on purpose, so nothing goes to History.
    func cancelRecording() async {
        guard let active = activeRun else { return }
        switch active.phase {
        case .arming:
            cancelArming(active)
        case .capturing:
            endCapture(of: active)
            await cancel(active)
        case .cancelling, .finalizing:
            return
        }
    }

    private func cancelArming(_ active: ActiveRecordingRun) {
        abortArming()
        state = readinessState
    }

    private func discardCapturing(_ active: ActiveRecordingRun) {
        endCapture(of: active)
        resyncSettingsFromSharedDefaults()
        let discarded = DiscardedRun(
            run: active.run,
            choice: RecordedOutputChoice(mode: selectedPromptMode, style: currentTextStyle)
        )

        setActiveRun(nil)
        state = .ready
        Logger.recording.info("Publishing cancelled: Discard during Capturing — the run goes to History")
        writeState(active.origin.deliversToKeyboard ? .cancelled : .idle)

        discardedRunFinalizer.finalize(discarded) { [weak self] outcome in
            // A run that started meanwhile owns the screen. The entry is in
            // History either way.
            guard let self, self.activeRun == nil else { return }
            self.discardNotes.show(outcome)
        }
    }

    /// The run terminates in cancellation: no Bundled Result, no Conversation.
    /// The `.cancelling` phase keeps a stop that lands while
    /// the run tears down from acting on it.
    private func cancel(_ active: ActiveRecordingRun) async {
        var cancelling = active
        cancelling.phase = .cancelling
        setActiveRun(cancelling)
        let terminalState = await active.run.cancel()
        guard activeRun?.run === active.run else { return }
        setActiveRun(nil)
        applyTerminalStateToUI(terminalState)
    }
}
