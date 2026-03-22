import Foundation
import AppKit
import OSLog

extension CaptureCoordinator {

    func handleRecordingStarted(isFollowUp: Bool) {
        if isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingStarted(isFollowUp=true) but panel is not visible — RC/CC disagree on follow-up status")
        }
        quickActionTask?.cancel()
        quickActionTask = nil
        pillResetTask?.cancel()
        autoDismissTask?.cancel()
        recordingIndicator.cancelPendingDismiss()
        // Dismiss any ephemeral indicator (dismissed/cancelled/success pill) so it
        // doesn't overlap with the new capture panel or recording indicator.
        recordingIndicator.hide()
        if isFollowUp && panel.isVisible {
            panel.lockForFollowUp()
            panel.setPhase(.recording)
        } else if !isFollowUp {
            showPanelMinimized(phase: .recording)
        }
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
        if result.isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingComplete(isFollowUp=true) but panel is not visible")
        }
        panel.unlockFollowUp()

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
                hadDestinationOverride: result.hadDestinationOverride,
                isFollowUp: result.isFollowUp
            )
            accumulatedCaptures = []
        }

        if let overrideID = mergedResult.destinationOverrideID {
            overrides.destinationOverride = overrideID
        }

        let mode = settings.activeMode
        let isQuickAction = !mergedResult.isFollowUp && (mode.quickAction || mergedResult.hadDestinationOverride)

        if isQuickAction {
            executeQuickAction(result: mergedResult, mode: mode)
        } else {
            populateWithTranscription(result: mergedResult)
        }
    }

    func handleTranscriptionFailed(isFollowUp: Bool) {
        panel.unlockFollowUp()
        quickActionTask?.cancel()
        quickActionTask = nil
        flashPill(phase: .error, duration: Self.pillErrorDisplayDuration)
        if !isFollowUp {
            scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
        }
    }

    func handleRecordingCancelled(wasFollowUp: Bool, wasFreshPill: Bool) {
        Task { await clipboardMonitor.stop() }
        accumulatedCaptures = []
        panel.unlockFollowUp()
        guard panel.isVisible else { return }
        flashPill(phase: .cancelled, shouldMinimize: true, duration: Self.pillFlashDuration)
        if wasFreshPill {
            scheduleAutoDismiss(after: Self.pillFlashDuration)
        }
    }

    func handleRecordingFailed(message: String) {
        panel.unlockFollowUp()
        quickActionTask?.cancel()
        quickActionTask = nil
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
        pillResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            panel.setPhase(.idle)
        }
    }

    func scheduleAutoDismiss(after duration: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.cancelCapture()
        }
    }

    func populateWithTranscription(result: RecordingResult) {
        if session == nil {
            session = PipelineSession()
            session?.previousActiveApp = result.previousActiveApp
        }
        if session?.conversationID == nil {
            session?.conversationID = UUID()
        }
        guard let activeSession = session, let currentConversationID = activeSession.conversationID else {
            Logger.app.error("populateWithTranscription: session unexpectedly nil")
            return
        }

        let newCaptures = result.captures

        if panel.isVisible {
            updateVisiblePanel(text: result.text, newCaptures: newCaptures)
        } else {
            showNewPanel(text: result.text, newCaptures: newCaptures)
        }

        panel.expand()
        recordingIndicator.hide()

        if session?.hasUnsubmittedDraft == true {
            let fullText = panel.fullText
            recordOrUpdateHistory(
                hasUnsubmittedDraft: true,
                conversationID: currentConversationID,
                input: fullText, output: fullText,
                captures: session?.captures ?? [],
                mode: settings.activeMode, hadExternalProcessing: false
            )
        } else {
            recordOrUpdateHistory(
                hasUnsubmittedDraft: false,
                conversationID: currentConversationID,
                input: result.text, output: result.text,
                captures: newCaptures,
                mode: settings.activeMode, hadExternalProcessing: false
            )
            session?.hasUnsubmittedDraft = true
        }

        overrides.markPipelineCompleted()
        Logger.app.info("Pipeline: handed to capture view")
    }

    private func updateVisiblePanel(text: String, newCaptures: [CapturedContext]) {
        panel.setPhase(.idle)

        let hasOnlyEmptySegment = panel.segmentCount == 1
            && panel.fullText.isEmpty && panel.allCaptures.isEmpty

        if hasOnlyEmptySegment {
            panel.setSegments([makeInitialSegment(text: text, capture: newCaptures.first)])
        } else if let capture = newCaptures.first {
            panel.appendSegment(InputSegment(text: text, capture: capture))
        } else {
            panel.appendTextToActiveSegment(text)
        }

        session?.captures.append(contentsOf: newCaptures)
    }

    private func showNewPanel(text: String, newCaptures: [CapturedContext]) {
        session?.captures = newCaptures
        showPanelWithSegments([makeInitialSegment(text: text, capture: newCaptures.first)])
    }

    private func makeInitialSegment(text: String, capture: CapturedContext?) -> InputSegment {
        if let capture {
            return InputSegment(text: text, capture: capture)
        }
        return InputSegment(text: text)
    }

    func showPanelWithSegments(_ segments: [InputSegment]) {
        let turns = session?.conversationTurns ?? []
        configurePanelAndShow(conversationTurns: turns, segments: segments)
    }

    func showPanelMinimized(phase: CaptureViewModel.CapturePhase) {
        configurePanelAndShow(minimized: true)
        panel.setPhase(phase)
        panel.minimize()
    }

    // MARK: - Settings + Re-registration

    func updatePushToTypeKeyCode(_ code: UInt16) {
        settings.pushToTypeHotkey.keyCode = code
        setupHotkey()
    }

    func updatePushToTypeModifiers(_ mods: UInt64) {
        settings.pushToTypeHotkey.modifiers = mods
        setupHotkey()
    }
}

// MARK: - RecordingCoordinatorDelegate

extension CaptureCoordinator: RecordingCoordinatorDelegate {

    func recordingCoordinatorWillStartRecording() {
        onWillStartInput?()
    }

    func recordingCoordinatorIsPanelVisible() -> Bool {
        // A panel showing only because of a pending quick action or scheduled
        // auto-dismiss is a transient leftover from the previous recording cycle
        // and should not cause the new recording to be treated as a follow-up.
        if quickActionTask != nil || autoDismissTask != nil { return false }
        return isPanelVisible
    }

    func recordingCoordinatorDidStartRecording(isFollowUp: Bool) {
        handleRecordingStarted(isFollowUp: isFollowUp)
    }

    func recordingCoordinatorDidStartTranscribing() {
        handleTranscribing()
    }

    func recordingCoordinatorDidCompleteRecording(result: RecordingResult) {
        handleRecordingComplete(result: result)
    }

    func recordingCoordinatorDidFailTranscription(isFollowUp: Bool) {
        handleTranscriptionFailed(isFollowUp: isFollowUp)
    }

    func recordingCoordinatorDidCancelRecording(wasFollowUp: Bool, wasFreshPill: Bool) {
        handleRecordingCancelled(wasFollowUp: wasFollowUp, wasFreshPill: wasFreshPill)
    }

    func recordingCoordinatorDidFailRecording(message: String) {
        handleRecordingFailed(message: message)
    }

    func recordingCoordinatorDidRejectInput() {
        panel.buzz()
    }

    func recordingCoordinatorDidCaptureSelection() {
        panel.signalClipboardCapture()
        // Start clipboard monitoring after SelectionCapturer finishes — same pattern
        // as push-to-type. Take a fresh baseline to avoid false positives from
        // SelectionCapturer's clipboard manipulation.
        let freshBaseline = NSPasteboard.general.changeCount
        Task {
            await clipboardMonitor.start(baselineChangeCount: freshBaseline) { [weak self] _ in
                self?.panel.signalClipboardCapture()
            }
        }
    }
}
