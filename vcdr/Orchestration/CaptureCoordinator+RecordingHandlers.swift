import Foundation
import AppKit
import OSLog

extension CaptureCoordinator {

    func handleRecordingStarted() {
        immediateActionTask?.cancel()
        immediateActionTask = nil
        pillResetTask?.cancel()
        autoDismissTask?.cancel()
        recordingIndicator.cancelPendingDismiss()
        // Dismiss any ephemeral indicator (dismissed/cancelled/success pill) so it
        // doesn't overlap with the new capture panel or recording indicator.
        recordingIndicator.hide()
        // Every recording is fresh — always show a new minimized pill
        showPanelMinimized(phase: .recording)
    }

    func handleTranscribing() {
        panel.setPhase(.processing)
        // Stop clipboard monitoring and store captures before transcription completes.
        // The transcription await gives this Task time to finish first.
        Task {
            let clips = await clipboardMonitor.stop()
            for text in clips {
                accumulatedCaptures.append(CapturedContext(text: text, source: .clipboard))
            }
        }
    }

    func handleRecordingComplete(result: RecordingResult) {
        // Merge clipboard captures accumulated during recording into the result
        let mergedResult: RecordingResult
        if accumulatedCaptures.isEmpty {
            mergedResult = result
        } else {
            mergedResult = RecordingResult(
                text: result.text,
                captures: result.captures + accumulatedCaptures,
                previousActiveApp: result.previousActiveApp,
                destinationOverrideID: result.destinationOverrideID,
                hadDestinationOverride: result.hadDestinationOverride
            )
            accumulatedCaptures = []
        }

        if let overrideID = mergedResult.destinationOverrideID {
            overrides.destinationOverride = overrideID
        }

        let mode = settings.activeMode
        executeImmediateAction(result: mergedResult, mode: mode)
    }

    func handleTranscriptionFailed() {
        immediateActionTask?.cancel()
        immediateActionTask = nil
        panel.setError("No speech detected")
        scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
    }

    func handleRecordingCancelled() {
        Task { await clipboardMonitor.stop() }
        accumulatedCaptures = []
        cancelCapture()
    }

    func handleRecordingFailed(message: String) {
        immediateActionTask?.cancel()
        immediateActionTask = nil
        panel.setError(message)
        scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
    }

    func flashPill(
        phase: CaptureViewModel.CapturePhase,
        shouldMinimize: Bool = false,
        duration: Duration
    ) {
        guard panel.isVisible else { return }
        panel.setPhase(phase)
        if shouldMinimize && !panel.isMinimized { panel.minimize() }
        pillResetTask?.cancel()
        // Brief visual flash: show the phase on the pill, then reset to idle after the duration
        pillResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            panel.setPhase(.idle)
        }
    }

    func scheduleAutoDismiss(after duration: Duration) {
        autoDismissTask?.cancel()
        // Auto-dismiss the capture panel after the configured duration if user doesn't interact
        autoDismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.cancelCapture()
        }
    }

    func showPanelMinimized(phase: CaptureViewModel.CapturePhase) {
        configurePanelAndShow(minimized: true)
        panel.setPhase(phase)
        panel.minimize()
    }

}

// MARK: - RecordingCoordinatorDelegate

extension CaptureCoordinator: RecordingCoordinatorDelegate {

    func recordingCoordinatorWillStartRecording() {
        onWillStartInput?()
    }

    func recordingCoordinatorDidStartRecording() {
        handleRecordingStarted()
    }

    func recordingCoordinatorDidStartTranscribing() {
        handleTranscribing()
    }

    func recordingCoordinatorDidCompleteRecording(result: RecordingResult) {
        handleRecordingComplete(result: result)
    }

    func recordingCoordinatorDidFailTranscription() {
        handleTranscriptionFailed()
    }

    func recordingCoordinatorDidCancelRecording() {
        handleRecordingCancelled()
    }

    func recordingCoordinatorDidFailRecording(message: String) {
        handleRecordingFailed(message: message)
    }

    func recordingCoordinatorDidRejectInput() {
        panel.buzz()
    }

    func recordingCoordinatorSelectionCaptureFinished(didCapture: Bool) {
        if didCapture {
            panel.signalClipboardCapture()
        }
        // Start clipboard monitoring after SelectionCapturer finishes.
        // Take a fresh baseline to avoid false positives from
        // SelectionCapturer's clipboard manipulation.
        let freshBaseline = NSPasteboard.general.changeCount
        Task {
            await clipboardMonitor.start(baselineChangeCount: freshBaseline) { [weak self] _ in
                self?.panel.signalClipboardCapture()
            }
        }
    }
}
