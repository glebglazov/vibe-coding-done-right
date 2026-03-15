import Foundation
import AppKit
import OSLog

extension CaptureCoordinator {

    func handleRecordingStarted(isFollowUp: Bool) {
        if isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingStarted(isFollowUp=true) but panel is not visible — RC/CC disagree on follow-up status")
        }
        pillResetTask?.cancel()
        autoDismissTask?.cancel()
        recordingIndicator.cancelPendingDismiss()
        if isFollowUp && panel.isVisible {
            panel.lockForFollowUp()
            panel.setPhase(.recording)
        } else if !isFollowUp && !settings.activeMode.quickAction {
            showPanelMinimized(phase: .recording)
        }
    }

    func handleTranscribing() {
        panel.setPhase(.processing)
    }

    func handleRecordingComplete(result: RecordingResult) {
        if result.isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingComplete(isFollowUp=true) but panel is not visible")
        }
        panel.unlockFollowUp()

        if let overrideID = result.destinationOverrideID {
            overrides.destinationOverride = overrideID
        }

        let mode = settings.activeMode
        let isQuickAction = !result.isFollowUp && (mode.quickAction || result.hadDestinationOverride)

        if isQuickAction {
            executeQuickAction(result: result, mode: mode)
        } else {
            populateWithTranscription(result: result)
        }
    }

    func handleTranscriptionFailed(isFollowUp: Bool) {
        panel.unlockFollowUp()
        if isFollowUp && panel.isVisible {
            flashPill(phase: .error, duration: Self.pillErrorDisplayDuration)
        } else if panel.isVisible {
            flashPill(phase: .error, duration: Self.pillErrorDisplayDuration)
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillErrorDisplayDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if !isFollowUp {
            recordingIndicator.update(phase: .error, message: "No speech detected")
            recordingIndicator.dismissAfterDelay(Self.errorIndicatorDuration)
        }
    }

    func handleRecordingCancelled(wasFollowUp: Bool, wasFreshPill: Bool) {
        panel.unlockFollowUp()
        if panel.isVisible && wasFreshPill {
            flashPill(phase: .cancelled, shouldMinimize: true, duration: Self.pillFlashDuration)
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if panel.isVisible && wasFollowUp {
            flashPill(phase: .cancelled, shouldMinimize: true, duration: Self.pillFlashDuration)
        }
    }

    func handleRecordingFailed(message: String) {
        panel.unlockFollowUp()
        panel.setPhase(.idle)
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
        let hasNewCapture = !newCaptures.isEmpty

        if panel.isVisible {
            panel.setPhase(.idle)

            let hasOnlyEmptySegment = panel.segmentCount == 1
                && panel.fullText.isEmpty && panel.allCaptures.isEmpty

            if hasOnlyEmptySegment {
                if hasNewCapture {
                    let capture = newCaptures[0]
                    panel.setSegments([InputSegment(text: result.text, capture: capture)])
                } else {
                    panel.setSegments([InputSegment(text: result.text)])
                }
            } else if hasNewCapture {
                let capture = newCaptures[0]
                let segment = InputSegment(text: result.text, capture: capture)
                panel.appendSegment(segment)
            } else {
                panel.appendTextToActiveSegment(result.text)
            }

            session?.captures.append(contentsOf: newCaptures)
        } else {
            session?.captures = newCaptures
            let segments: [InputSegment]
            if let capture = newCaptures.first {
                segments = [InputSegment(text: result.text, capture: capture)]
            } else {
                segments = [InputSegment(text: result.text)]
            }
            showPanelWithSegments(segments)
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

    func showPanelWithSegments(_ segments: [InputSegment]) {
        let turns = session?.conversationTurns ?? []
        configurePanelAndShow(conversationTurns: turns, segments: segments)
    }

    func showPanelMinimized(phase: CaptureViewModel.CapturePhase) {
        configurePanelAndShow()
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
