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
        let pipelineSession = session ?? PipelineSession()
        let mode = settings.activeMode
        let conversationID = pipelineSession.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)

        let pipelineContext = SubmissionPipeline.Context(
            text: text,
            mode: mode,
            captures: [],  // captures are already inline in text via <capture-N> tags
            followUpContext: pipelineSession.followUpContext,
            conversationTurns: pipelineSession.conversationTurns,
            conversationID: conversationID,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            destination: destination,
            targetAppPID: pipelineSession.previousActiveApp?.processIdentifier
        )

        return SubmissionSnapshot(
            pipelineContext: pipelineContext,
            mode: mode,
            captures: pipelineSession.captures,
            hasUnsubmittedDraft: pipelineSession.hasUnsubmittedDraft,
            conversationID: conversationID,
            previousActiveApp: pipelineSession.previousActiveApp,
            useStreaming: destination.type == .outputPanel && mode.processingType == .bashScript,
            destination: destination
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

    func executeQuickAction(result: RecordingResult, mode: Mode) {
        let captures = result.captures
        let previousActiveApp = result.previousActiveApp
        let conversationID = session?.conversationID ?? UUID()
        let currentTurns = session?.conversationTurns ?? []
        let followUpContext = session?.followUpContext
        let targetAppPID = previousActiveApp?.processIdentifier
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)

        let pipelineContext = SubmissionPipeline.Context(
            text: result.text,
            mode: mode,
            captures: captures,
            followUpContext: followUpContext,
            conversationTurns: currentTurns,
            conversationID: conversationID,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            destination: destination,
            targetAppPID: targetAppPID
        )

        Task { @MainActor in
            do {
                let pipelineResult = try await SubmissionPipeline.run(context: pipelineContext)

                if destination.type == .outputPanel {
                    let turn = ConversationTurn(input: result.text, output: pipelineResult.processedText, captures: captures)
                    panel.dismiss()
                    session = PipelineSession()
                    session?.previousActiveApp = previousActiveApp
                    session?.captures = captures
                    session?.conversationID = conversationID
                    session?.conversationTurns = [turn]
                    session?.followUpContext = pipelineResult.processedText
                    let segments: [InputSegment]
                    if captures.isEmpty {
                        segments = [InputSegment()]
                    } else {
                        segments = [InputSegment(capture: captures.first)]
                            + captures.dropFirst().map { InputSegment(capture: $0) }
                    }
                    configurePanelAndShow(conversationTurns: [turn], segments: segments)
                    if pipelineResult.hadExternalProcessing {
                        panel.setProcessedByModeName(mode.name)
                    }
                    recordingIndicator.hide()
                } else {
                    panel.dismiss()
                    recordingIndicator.showSuccess(destinationName: destination.name.lowercased())
                }

                SubmissionPipeline.recordTurn(
                    history: transcriptionHistory,
                    conversationID: conversationID,
                    input: result.text,
                    output: pipelineResult.processedText,
                    captures: captures,
                    modeID: mode.id,
                    modeName: mode.name,
                    hadExternalProcessing: pipelineResult.hadExternalProcessing
                )

                overrides.markPipelineCompleted()
                Logger.app.info("Quick action pipeline complete")
            } catch {
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                recordingIndicator.dismissAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Quick action pipeline failed: \(error)")
            }
        }
    }

    func executeStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let streamResult = SubmissionPipeline.runStreaming(context: snapshot.pipelineContext)
        // Save full panel state before startProcessing clears it — restored on error.
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
                    followUpContext: accumulated,
                    previousActiveApp: snapshot.previousActiveApp
                )
                self.overrides.markPipelineCompleted()
                self.rewirePanelCallbacks()
                Logger.app.info("Capture view: streaming complete")
            } catch {
                streamResult.cancel()
                panel.restoreConversation(turns: savedTurns, segments: savedSegments, error: error.localizedDescription)
                self.rebuildSessionAfterError(snapshot: snapshot, followUpContext: snapshot.pipelineContext.followUpContext)
                self.rewirePanelCallbacks()
                Logger.app.error("Capture view streaming failed: \(error)")
            }
        }
    }

    func executeNonStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        // Save pre-submission state — restored if processing itself fails.
        let savedSegments = panel.viewModel?.segments ?? [InputSegment()]
        let savedTurns = panel.currentTurns

        if snapshot.mode.processingType == .bashScript {
            panel.startProcessing(inputText: text)
        }

        Task { @MainActor in
            // Step 1: Process text
            let result: SubmissionPipeline.Result
            do {
                result = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                // Processing failed — restore pre-submission state
                panel.restoreConversation(turns: savedTurns, segments: savedSegments, error: error.localizedDescription)
                self.rebuildSessionAfterError(snapshot: snapshot, followUpContext: snapshot.pipelineContext.followUpContext)
                self.rewirePanelCallbacks()
                Logger.app.error("Capture view processing failed: \(error)")
                return
            }

            // Processing succeeded — commit the result as a conversation turn.
            // This is the state we restore to if the action fails below.
            if snapshot.mode.processingType == .bashScript {
                panel.finishProcessing(outputText: result.processedText)
                if result.hadExternalProcessing {
                    panel.setProcessedByModeName(snapshot.mode.name)
                }
            }

            // Step 2: Execute output action
            do {
                try await SubmissionPipeline.executeAction(context: snapshot.pipelineContext, processedText: result.processedText)
            } catch {
                // Action failed — processing result is already committed as a conversation turn,
                // so start with empty segments (not savedSegments which would duplicate the input).
                panel.setError(error.localizedDescription)
                panel.setSegments([InputSegment()])
                recordOrUpdateHistory(
                    hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
                    conversationID: snapshot.conversationID,
                    input: text, output: result.processedText, captures: snapshot.captures,
                    mode: snapshot.mode, hadExternalProcessing: result.hadExternalProcessing
                )
                self.rebuildSessionAfterError(snapshot: snapshot)
                self.rewirePanelCallbacks()
                Logger.app.error("Capture view action failed: \(error)")
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
                    followUpContext: result.processedText,
                    previousActiveApp: snapshot.previousActiveApp
                )
            }

            self.overrides.markPipelineCompleted()
            if panel.isVisible {
                self.rewirePanelCallbacks()
            }
            Logger.app.info("Capture view: pipeline complete")
        }
    }

    func recordOrUpdateHistory(
        hasUnsubmittedDraft: Bool,
        conversationID: UUID,
        input: String,
        output: String,
        captures: [CapturedContext],
        mode: Mode,
        hadExternalProcessing: Bool
    ) {
        if hasUnsubmittedDraft {
            SubmissionPipeline.updateLastTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name,
                hadExternalProcessing: hadExternalProcessing
            )
        } else {
            SubmissionPipeline.recordTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name,
                hadExternalProcessing: hadExternalProcessing
            )
        }
    }

    func rebuildSessionForFollowUp(
        conversationID: UUID,
        followUpContext: String,
        previousActiveApp: NSRunningApplication?
    ) {
        session = PipelineSession()
        session?.conversationTurns = panel.currentTurns
        session?.conversationID = conversationID
        session?.followUpContext = followUpContext
        session?.previousActiveApp = previousActiveApp
    }

    /// Rebuilds the session after a pipeline error so the capture view
    /// continues to function (user can change mode/destination and retry).
    /// Pass the previous followUpContext when the conversation state hasn't changed
    /// (processing failed). Leave nil when a new turn was added (action failed) —
    /// the conversation turns already carry the context.
    func rebuildSessionAfterError(snapshot: SubmissionSnapshot, followUpContext: String? = nil) {
        session = PipelineSession()
        session?.conversationTurns = panel.currentTurns
        session?.conversationID = snapshot.conversationID
        session?.captures = panel.allCaptures
        session?.previousActiveApp = snapshot.previousActiveApp
        session?.followUpContext = followUpContext
    }
}
