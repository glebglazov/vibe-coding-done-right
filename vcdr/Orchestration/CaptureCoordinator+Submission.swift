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
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                destination: destination, targetAppPID: ps.previousActiveApp?.processIdentifier,
                saveResultToClipboard: mode.saveResultToClipboard
            ),
            mode: mode,
            inputSegments: panel.viewModel?.inputSegments ?? [InputSegment()],
            conversationID: conversationID, previousActiveApp: ps.previousActiveApp,
            useStreaming: destination.type == .outputPanel && mode.processingType == .bashScript,
            destination: destination
        )
    }

    func captureImmediateActionSnapshot(result: RecordingResult, mode: Mode) -> SubmissionSnapshot {
        let conversationID = session?.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        let quickSegments = Self.makeSegments(text: result.text, captures: result.captures)
        return SubmissionSnapshot(
            pipelineContext: .init(
                text: result.text, mode: mode, captures: result.captures,
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                destination: destination, targetAppPID: result.previousActiveApp?.processIdentifier,
                saveResultToClipboard: mode.saveResultToClipboard
            ),
            mode: mode,
            inputSegments: quickSegments,
            conversationID: conversationID, previousActiveApp: result.previousActiveApp,
            useStreaming: false, destination: destination
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

    /// Recovers from a processing failure — restore pre-submission state.
    private func recoverFromProcessingError(
        _ error: Error, snapshot: SubmissionSnapshot,
        savedSegments: [InputSegment]
    ) {
        panel.restoreFromError(inputSegments: savedSegments, error: error.localizedDescription)
        rebuildSessionAfterError(snapshot: snapshot)
        rewirePanelCallbacks()
        recordingIndicator.hide()
        Logger.app.error("Pipeline processing failed: \(error)")
    }

    /// Recovers from an action failure — add error banner and record history.
    private func recoverFromActionError(
        _ error: Error, snapshot: SubmissionSnapshot,
        output: String?
    ) {
        panel.setError(error.localizedDescription)
        panel.setSegments([InputSegment()])
        recordHistory(
            conversationID: snapshot.conversationID,
            inputSegments: snapshot.inputSegments, output: output,
            mode: snapshot.mode
        )
        rebuildSessionAfterError(snapshot: snapshot)
        rewirePanelCallbacks()
        recordingIndicator.hide()
        Logger.app.error("Pipeline action failed: \(error)")
    }

    // MARK: - Submission Paths

    func executeImmediateAction(result: RecordingResult, mode: Mode) {
        let snapshot = captureImmediateActionSnapshot(result: result, mode: mode)

        // Populate the panel with transcribed text so user can see it if they expand
        panel.populateImmediateActionText(inputSegments: snapshot.inputSegments)

        immediateActionTask = Task { @MainActor in
            let pipelineResult: SubmissionPipeline.Result
            do {
                pipelineResult = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                guard !Task.isCancelled else { return }
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedSegments: [InputSegment()]
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
            immediateActionTask = nil

            // Full success
            if snapshot.destination.type == .outputPanel {
                if pipelineResult.hadExternalProcessing {
                    panel.finishProcessing(outputText: pipelineResult.processedText)
                    panel.setProcessedByModeName(snapshot.mode.name)
                } else {
                    panel.finishProcessingWithoutOutput()
                }
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
                self.overrides.markPipelineCompleted()
                Logger.app.info("Capture view: streaming complete")
            } catch {
                streamResult.cancel()
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedSegments: savedSegments
                )
            }
        }
    }

    func executeNonStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let savedSegments = panel.viewModel?.inputSegments ?? [InputSegment()]
        if snapshot.mode.processingType == .bashScript {
            panel.startProcessing()
        }

        Task { @MainActor in
            let result: SubmissionPipeline.Result
            do {
                result = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                recoverFromProcessingError(
                    error, snapshot: snapshot, savedSegments: savedSegments
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
            self.overrides.markPipelineCompleted()
            Logger.app.info("Capture view: pipeline complete")
        }
    }

    // MARK: - Session & History Helpers

    /// Single entry point for recording a completed submission to history.
    /// Encapsulates the rule: output is only stored when external processing occurred.
    func finalizeHistory(snapshot: SubmissionSnapshot, processedText: String, hadExternalProcessing: Bool) {
        let output = hadExternalProcessing ? processedText : nil
        recordHistory(
            conversationID: snapshot.conversationID,
            inputSegments: snapshot.inputSegments, output: output,
            mode: snapshot.mode
        )
    }

    func recordHistory(
        conversationID: UUID,
        inputSegments: [InputSegment], output: String?,
        mode: Mode
    ) {
        SubmissionPipeline.recordHistory(
            history: transcriptionHistory, conversationID: conversationID,
            inputSegments: inputSegments, output: output,
            modeID: mode.id, modeName: mode.name
        )
    }

    /// Rebuilds session after a pipeline error so the user can retry.
    func rebuildSessionAfterError(snapshot: SubmissionSnapshot) {
        session = PipelineSession()
        session?.conversationID = snapshot.conversationID
        session?.captures = panel.allCaptures
        session?.previousActiveApp = snapshot.previousActiveApp
    }
}
