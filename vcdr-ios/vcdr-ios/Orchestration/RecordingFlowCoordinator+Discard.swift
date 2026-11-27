import Foundation
import OSLog

/// Discard (ADR-0010): the run ends at once and never blocks the next run.
/// The words of a run discarded during Capturing go to History.
extension RecordingFlowCoordinator {
    /// The user's Discard. During Arming no audio exists, so nothing is saved.
    /// During Capturing the run ends at once, and the Discarded Run Finalizer
    /// saves its verbatim transcript in the background.
    func discardRecording() async {
        guard let active = activeRun else { return }
        switch active.run.phase {
        case .arming:
            Logger.app.info("[RecordTiming] discardRecording during Arming — nothing to save")
            discardNotes.show(.nothingSaved)
            _ = await active.run.cancel()
        case .capturing:
            await discardCapturing(active)
        case .finalizing, .ended:
            return
        }
    }

    /// Ends the run with no result, for a caller that is not the user: a
    /// Shortcut start whose card the system refused. No speech was captured
    /// on purpose, so nothing goes to History.
    func cancelRecording() async {
        guard let active = activeRun else { return }
        switch active.run.phase {
        case .arming, .capturing:
            _ = await active.run.cancel()
        case .finalizing, .ended:
            return
        }
    }

    private func discardCapturing(_ active: ActiveRecordingRun) async {
        resyncSettingsFromSharedDefaults()
        let discarded = DiscardedRun(
            run: active.run,
            choice: RecordedOutputChoice(mode: selectedPromptMode, style: currentTextStyle)
        )

        Logger.recording.info("Discard during Capturing — the run goes to History")
        await active.run.discard()

        discardedRunFinalizer.finalize(discarded) { [weak self] outcome in
            // A run that started meanwhile owns the screen. The entry is in
            // History either way.
            guard let self, self.activeRun == nil else { return }
            self.discardNotes.show(outcome)
        }
    }
}
