import Foundation
import AppKit
import OSLog

extension CaptureCoordinator {

    struct SubmissionSnapshot {
        let pipelineContext: SubmissionPipeline.Context
        let mode: Mode
        /// Raw input segments captured from the panel at submission time — stored in history as-is.
        let inputSegments: [InputSegment]
        let conversationID: UUID
        let previousActiveApp: NSRunningApplication?
        let useStreaming: Bool
        let destination: OutputDestination
        let historySourceConversationID: UUID?
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
                destination: destination, targetAppPID: ps.previousActiveApp?.processIdentifier,
                saveResultToClipboard: mode.saveResultToClipboard
            ),
            mode: mode,
            inputSegments: panel.viewModel?.inputSegments ?? [InputSegment()],
            conversationID: conversationID, previousActiveApp: ps.previousActiveApp,
            useStreaming: destination.type == .outputPanel && mode.processingType == .bashScript,
            destination: destination,
            historySourceConversationID: ps.historySourceConversationID
        )
    }

    func captureQuickActionSnapshot(result: RecordingResult, mode: Mode) -> SubmissionSnapshot {
        let conversationID = session?.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        let quickSegments = Self.makeSegments(text: result.text, captures: result.captures)
        return SubmissionSnapshot(
            pipelineContext: .init(
                text: result.text, mode: mode, captures: result.captures,
                followUpContext: session?.followUpContext,
                conversationTurns: session?.conversationTurns ?? [],
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                destination: destination, targetAppPID: result.previousActiveApp?.processIdentifier,
                saveResultToClipboard: mode.saveResultToClipboard
            ),
            mode: mode,
            inputSegments: quickSegments,
            conversationID: conversationID, previousActiveApp: result.previousActiveApp,
            useStreaming: false, destination: destination,
            historySourceConversationID: nil
        )
    }

    /// Constructs segments from raw text + captures (for quick action / recording paths).
    static func makeSegments(text: String, captures: [CapturedContext]) -> [InputSegment] {
        guard let first = captures.first else {
            return [InputSegment(text: text)]
        }
        var result = [InputSegment(text: text, capture: first)]
        for capture in captures.dropFirst() {
            result.append(InputSegment(capture: capture))
        }
        return result
    }

    func submitText(_ text: String) {
        // Ensure a history draft exists before submission. For recording sessions,
        // populateWithTranscription already created the draft. For push-to-type sessions,
        // this is the first write — it creates the capture record so Enter never adds a new one.
        ensureDraftExists()
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
        panel.restoreConversation(turns: savedTurns, inputSegments: savedSegments, error: error.localizedDescription)
        rebuildSessionAfterError(snapshot: snapshot, followUpContext: snapshot.pipelineContext.followUpContext)
        rewirePanelCallbacks()
        recordingIndicator.hide()
        Logger.app.error("Pipeline processing failed: \(error)")
    }

    /// Recovers from an action failure — the turn is already visible, add error banner and record history.
    private func recoverFromActionError(
        _ error: Error, snapshot: SubmissionSnapshot,
        output: String?
    ) {
        panel.setError(error.localizedDescription)
        panel.setSegments([InputSegment()])
        recordOrUpdateHistory(
            conversationID: snapshot.conversationID,
            inputSegments: snapshot.inputSegments, output: output,
            mode: snapshot.mode,
            historySourceConversationID: snapshot.historySourceConversationID
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
        panel.populateQuickActionText(inputSegments: snapshot.inputSegments)

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
                    error, snapshot: snapshot, output: pipelineResult.processedText
                )
                return
            }

            guard !Task.isCancelled else { return }
            quickActionTask = nil

            // Full success
            if snapshot.destination.type == .outputPanel {
                if pipelineResult.hadExternalProcessing {
                    // Show processed output as a conversation turn with labels
                    panel.finishProcessing(outputText: pipelineResult.processedText)
                    panel.setProcessedByModeName(snapshot.mode.name)
                } else {
                    // No external processing — just expand, output stays nil (no labels)
                    panel.finishProcessingWithoutOutput()
                }
                // Rebuild session for follow-up
                session = PipelineSession()
                session?.previousActiveApp = snapshot.previousActiveApp
                session?.captures = snapshot.inputSegments.compactMap(\.capture)
                session?.conversationID = snapshot.conversationID
                session?.conversationTurns = panel.currentTurns
                session?.followUpContext = pipelineResult.processedText
                rewirePanelCallbacks()
                recordingIndicator.hide()
            } else {
                panel.dismiss()
                recordingIndicator.showSuccess(destinationName: snapshot.destination.name.lowercased())
            }

            finalizeHistory(
                snapshot: snapshot, processedText: pipelineResult.processedText,
                hadExternalProcessing: pipelineResult.hadExternalProcessing
            )
            overrides.markPipelineCompleted()
            Logger.app.info("Quick action pipeline complete")
        }
    }

    func executeStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let streamResult = SubmissionPipeline.runStreaming(context: snapshot.pipelineContext)
        let savedSegments = panel.viewModel?.inputSegments ?? [InputSegment()]
        let savedTurns = panel.currentTurns
        panel.startProcessing()
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
                finalizeHistory(
                    snapshot: snapshot, processedText: accumulated,
                    hadExternalProcessing: streamResult.hadExternalProcessing
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
        let savedSegments = panel.viewModel?.inputSegments ?? [InputSegment()]
        let savedTurns = panel.currentTurns
        if snapshot.mode.processingType == .bashScript {
            panel.startProcessing()
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

            // Hide panel before paste so the target app can receive focus.
            // For outputPanel destinations the panel stays visible.
            let shouldHideForAction = snapshot.destination.type != .outputPanel
            if shouldHideForAction {
                panel.orderOut()
            }

            do {
                try await SubmissionPipeline.executeAction(
                    context: snapshot.pipelineContext, processedText: result.processedText
                )
            } catch {
                if shouldHideForAction {
                    panel.orderBack()
                }
                recoverFromActionError(
                    error, snapshot: snapshot, output: result.processedText
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

            finalizeHistory(
                snapshot: snapshot, processedText: result.processedText,
                hadExternalProcessing: result.hadExternalProcessing
            )
            if panel.isVisible {
                if result.hadExternalProcessing {
                    // Processing: rebuild for follow-up (new turn on next Enter)
                    rebuildSessionForFollowUp(
                        conversationID: snapshot.conversationID,
                        followUpContext: result.processedText,
                        previousActiveApp: snapshot.previousActiveApp
                    )
                } else {
                    // Non-processing: rebuild session but the draft turn in history
                    // still has output == nil, so hasUnsubmittedDraft is naturally true —
                    // subsequent Enters will update it, not create new turns.
                    session = PipelineSession()
                    session?.conversationID = snapshot.conversationID
                    session?.conversationTurns = panel.currentTurns
                    session?.previousActiveApp = snapshot.previousActiveApp
                }
            }
            self.overrides.markPipelineCompleted()
            if panel.isVisible { self.rewirePanelCallbacks() }
            Logger.app.info("Capture view: pipeline complete")
        }
    }

    // MARK: - Session & History Helpers

    /// Single entry point for recording a completed submission to history.
    /// Encapsulates the rule: output is only stored when external processing occurred.
    func finalizeHistory(snapshot: SubmissionSnapshot, processedText: String, hadExternalProcessing: Bool) {
        let output = hadExternalProcessing ? processedText : nil
        recordOrUpdateHistory(
            conversationID: snapshot.conversationID,
            inputSegments: snapshot.inputSegments, output: output,
            mode: snapshot.mode,
            historySourceConversationID: snapshot.historySourceConversationID
        )
    }

    func recordOrUpdateHistory(
        conversationID: UUID,
        inputSegments: [InputSegment], output: String?,
        mode: Mode,
        historySourceConversationID: UUID? = nil
    ) {
        // Fork: duplicate the source conversation under the new ID before the first write
        if let sourceID = historySourceConversationID {
            transcriptionHistory.duplicateConversation(originalID: sourceID, newID: conversationID)
        }

        if transcriptionHistory.hasUnsubmittedDraft(conversationID: conversationID) {
            SubmissionPipeline.updateLastTurn(
                history: transcriptionHistory, conversationID: conversationID,
                inputSegments: inputSegments, output: output,
                modeID: mode.id, modeName: mode.name
            )
        } else {
            SubmissionPipeline.recordTurn(
                history: transcriptionHistory, conversationID: conversationID,
                inputSegments: inputSegments, output: output,
                modeID: mode.id, modeName: mode.name
            )
        }
    }

    func rebuildSessionForFollowUp(
        conversationID: UUID, followUpContext: String?, previousActiveApp: NSRunningApplication?
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

    /// Ensures a history record exists before any submission write.
    /// - For history views: forks the conversation (new UUID, duplicate) on first mutation.
    /// - For push-to-type sessions: creates the initial draft turn.
    /// - For recording sessions: `populateWithTranscription` already created the draft — no-op.
    private func ensureDraftExists() {
        guard let session else { return }

        // Fork from history view: duplicate the original conversation under a new UUID.
        // Falls through to create a new draft turn if the last turn is completed.
        if let sourceID = session.historySourceConversationID {
            let newID = UUID()
            transcriptionHistory.duplicateConversation(originalID: sourceID, newID: newID)
            self.session?.conversationID = newID
            self.session?.historySourceConversationID = nil
        }

        // Create the initial draft if one doesn't exist yet.
        // After a fork with a completed last turn, this appends a new follow-up turn.
        // If the last turn is already a draft, this is skipped — it will be updated.
        guard let conversationID = self.session?.conversationID,
              !transcriptionHistory.hasUnsubmittedDraft(conversationID: conversationID) else { return }

        let segments = panel.viewModel?.inputSegments ?? [InputSegment()]
        SubmissionPipeline.recordTurn(
            history: transcriptionHistory, conversationID: conversationID,
            inputSegments: segments, output: nil,
            modeID: settings.activeMode.id, modeName: settings.activeMode.name
        )
    }
}
