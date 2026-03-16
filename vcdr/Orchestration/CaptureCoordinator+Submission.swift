import Foundation
import AppKit
import OSLog

extension CaptureCoordinator {

    struct SubmissionSnapshot {
        let pipelineContext: SubmissionPipeline.Context
        let mode: Mode
        let captures: [CapturedContext]
        let hasUnsubmittedDraft: Bool
        let conversationID: UUID
        let previousActiveApp: NSRunningApplication?
        let useStreaming: Bool
        let destination: OutputDestination
    }

    func captureSubmissionSnapshot(text: String) -> SubmissionSnapshot {
        let ps = session ?? PipelineSession()
        let mode = settings.activeMode
        let conversationID = ps.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        return SubmissionSnapshot(
            pipelineContext: .init(
                text: text, mode: mode,
                captures: [],  // captures are inline in text via <capture-N> tags
                followUpContext: ps.followUpContext, conversationTurns: ps.conversationTurns,
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                destination: destination, targetAppPID: ps.previousActiveApp?.processIdentifier
            ),
            mode: mode, captures: ps.captures, hasUnsubmittedDraft: ps.hasUnsubmittedDraft,
            conversationID: conversationID, previousActiveApp: ps.previousActiveApp,
            useStreaming: destination.type == .outputPanel && mode.processingType == .bashScript,
            destination: destination
        )
    }

    func captureQuickActionSnapshot(result: RecordingResult, mode: Mode) -> SubmissionSnapshot {
        let conversationID = session?.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        return SubmissionSnapshot(
            pipelineContext: .init(
                text: result.text, mode: mode, captures: result.captures,
                followUpContext: session?.followUpContext,
                conversationTurns: session?.conversationTurns ?? [],
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                destination: destination, targetAppPID: result.previousActiveApp?.processIdentifier
            ),
            mode: mode, captures: result.captures, hasUnsubmittedDraft: false,
            conversationID: conversationID, previousActiveApp: result.previousActiveApp,
            useStreaming: false, destination: destination
        )
    }

    func submitText(_ text: String) {
        let snapshot = captureSubmissionSnapshot(text: text)
        session = nil
        Logger.app.info("Capture view: executing pipeline")
        if snapshot.useStreaming {
            executeStreamingSubmission(snapshot, text: text)
        } else {
            executeNonStreamingSubmission(snapshot, text: text)
        }
    }

    // MARK: - Shared Error Recovery

    /// Recovers from a processing failure — no turn was committed, restore pre-submission state.
    private func recoverFromProcessingError(
        _ error: Error, snapshot: SubmissionSnapshot,
        savedTurns: [ConversationTurn], savedSegments: [InputSegment]
    ) {
        panel.restoreConversation(turns: savedTurns, segments: savedSegments, error: error.localizedDescription)
        rebuildSessionAfterError(snapshot: snapshot, followUpContext: snapshot.pipelineContext.followUpContext)
        rewirePanelCallbacks()
        recordingIndicator.hide()
        Logger.app.error("Pipeline processing failed: \(error)")
    }

    /// Recovers from an action failure — the turn is already visible, add error banner and record history.
    private func recoverFromActionError(
        _ error: Error, snapshot: SubmissionSnapshot,
        input: String, output: String, hadExternalProcessing: Bool
    ) {
        panel.setError(error.localizedDescription)
        panel.setSegments([InputSegment()])
        recordOrUpdateHistory(
            hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
            conversationID: snapshot.conversationID,
            input: input, output: output, captures: snapshot.captures,
            mode: snapshot.mode, hadExternalProcessing: hadExternalProcessing
        )
        rebuildSessionAfterError(snapshot: snapshot)
        rewirePanelCallbacks()
        recordingIndicator.hide()
        Logger.app.error("Pipeline action failed: \(error)")
    }

    // MARK: - Submission Paths

    func executeQuickAction(result: RecordingResult, mode: Mode) {
        let snapshot = captureQuickActionSnapshot(result: result, mode: mode)

        // Populate the panel with transcribed text so user can see it if they expand
        panel.populateQuickActionText(inputText: result.text, captures: result.captures)

        quickActionTask = Task { @MainActor in
            let pipelineResult: SubmissionPipeline.Result
            do {
                pipelineResult = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                guard !Task.isCancelled else { return }
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedTurns: [], savedSegments: [InputSegment()]
                )
                return
            }

            guard !Task.isCancelled else { return }

            do {
                try await SubmissionPipeline.executeAction(
                    context: snapshot.pipelineContext, processedText: pipelineResult.processedText
                )
            } catch {
                guard !Task.isCancelled else { return }
                recoverFromActionError(
                    error, snapshot: snapshot, input: result.text, output: pipelineResult.processedText,
                    hadExternalProcessing: pipelineResult.hadExternalProcessing
                )
                return
            }

            guard !Task.isCancelled else { return }
            quickActionTask = nil

            // Full success
            if snapshot.destination.type == .outputPanel {
                // Update the pending turn with processed text and expand
                panel.finishProcessing(outputText: pipelineResult.processedText)
                if pipelineResult.hadExternalProcessing {
                    panel.setProcessedByModeName(snapshot.mode.name)
                }
                // Rebuild session for follow-up
                session = PipelineSession()
                session?.previousActiveApp = snapshot.previousActiveApp
                session?.captures = snapshot.captures
                session?.conversationID = snapshot.conversationID
                session?.conversationTurns = panel.currentTurns
                session?.followUpContext = pipelineResult.processedText
                rewirePanelCallbacks()
                recordingIndicator.hide()
            } else {
                panel.dismiss()
                recordingIndicator.showSuccess(destinationName: snapshot.destination.name.lowercased())
            }

            SubmissionPipeline.recordTurn(
                history: transcriptionHistory, conversationID: snapshot.conversationID,
                input: result.text, output: pipelineResult.processedText, captures: snapshot.captures,
                modeID: snapshot.mode.id, modeName: snapshot.mode.name,
                hadExternalProcessing: pipelineResult.hadExternalProcessing
            )
            overrides.markPipelineCompleted()
            Logger.app.info("Quick action pipeline complete")
        }
    }

    func executeStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let streamResult = SubmissionPipeline.runStreaming(context: snapshot.pipelineContext)
        let savedSegments = panel.viewModel?.segments ?? [InputSegment()]
        let savedTurns = panel.currentTurns
        panel.startProcessing(inputText: text)
        recordingIndicator.hide()

        Task { @MainActor in
            var accumulated = ""
            do {
                for try await chunk in streamResult.chunks {
                    accumulated += chunk
                    panel.updateStreamingOutput(accumulated)
                }
                panel.finishStreaming(outputText: accumulated)
                if streamResult.hadExternalProcessing {
                    panel.setProcessedByModeName(snapshot.mode.name)
                }
                panel.makeKeyIfVisible()
                recordOrUpdateHistory(
                    hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
                    conversationID: snapshot.conversationID,
                    input: text, output: accumulated, captures: snapshot.captures,
                    mode: snapshot.mode, hadExternalProcessing: streamResult.hadExternalProcessing
                )
                rebuildSessionForFollowUp(
                    conversationID: snapshot.conversationID,
                    followUpContext: accumulated, previousActiveApp: snapshot.previousActiveApp
                )
                self.overrides.markPipelineCompleted()
                self.rewirePanelCallbacks()
                Logger.app.info("Capture view: streaming complete")
            } catch {
                streamResult.cancel()
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedTurns: savedTurns, savedSegments: savedSegments
                )
            }
        }
    }

    func executeNonStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let savedSegments = panel.viewModel?.segments ?? [InputSegment()]
        let savedTurns = panel.currentTurns
        if snapshot.mode.processingType == .bashScript {
            panel.startProcessing(inputText: text)
        }

        Task { @MainActor in
            let result: SubmissionPipeline.Result
            do {
                result = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedTurns: savedTurns, savedSegments: savedSegments
                )
                return
            }

            // Processing succeeded — commit the turn before attempting the action
            if snapshot.mode.processingType == .bashScript {
                panel.finishProcessing(outputText: result.processedText)
                if result.hadExternalProcessing {
                    panel.setProcessedByModeName(snapshot.mode.name)
                }
            }

            do {
                try await SubmissionPipeline.executeAction(
                    context: snapshot.pipelineContext, processedText: result.processedText
                )
            } catch {
                recoverFromActionError(
                    error, snapshot: snapshot, input: text, output: result.processedText,
                    hadExternalProcessing: result.hadExternalProcessing
                )
                return
            }

            // Full success
            if snapshot.destination.type == .outputPanel {
                recordingIndicator.hide()
                panel.makeKeyIfVisible()
            } else {
                panel.dismiss()
                recordingIndicator.showSuccess(destinationName: snapshot.destination.name.lowercased())
            }

            recordOrUpdateHistory(
                hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
                conversationID: snapshot.conversationID,
                input: text, output: result.processedText, captures: snapshot.captures,
                mode: snapshot.mode, hadExternalProcessing: result.hadExternalProcessing
            )
            if panel.isVisible && result.hadExternalProcessing {
                rebuildSessionForFollowUp(
                    conversationID: snapshot.conversationID,
                    followUpContext: result.processedText, previousActiveApp: snapshot.previousActiveApp
                )
            }
            self.overrides.markPipelineCompleted()
            if panel.isVisible { self.rewirePanelCallbacks() }
            Logger.app.info("Capture view: pipeline complete")
        }
    }

    // MARK: - Session & History Helpers

    func recordOrUpdateHistory(
        hasUnsubmittedDraft: Bool, conversationID: UUID,
        input: String, output: String, captures: [CapturedContext],
        mode: Mode, hadExternalProcessing: Bool
    ) {
        if hasUnsubmittedDraft {
            SubmissionPipeline.updateLastTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name, hadExternalProcessing: hadExternalProcessing
            )
        } else {
            SubmissionPipeline.recordTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name, hadExternalProcessing: hadExternalProcessing
            )
        }
    }

    func rebuildSessionForFollowUp(
        conversationID: UUID, followUpContext: String, previousActiveApp: NSRunningApplication?
    ) {
        session = PipelineSession()
        session?.conversationTurns = panel.currentTurns
        session?.conversationID = conversationID
        session?.followUpContext = followUpContext
        session?.previousActiveApp = previousActiveApp
    }

    /// Rebuilds session after a pipeline error. Pass followUpContext when conversation
    /// state hasn't changed (processing failed). Leave nil when a new turn was added.
    func rebuildSessionAfterError(snapshot: SubmissionSnapshot, followUpContext: String? = nil) {
        session = PipelineSession()
        session?.conversationTurns = panel.currentTurns
        session?.conversationID = snapshot.conversationID
        session?.captures = panel.allCaptures
        session?.previousActiveApp = snapshot.previousActiveApp
        session?.followUpContext = followUpContext
    }
}
