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
        let destination: OutputDestination
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
            destination: destination
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

    // MARK: - Submission Paths

    func executeImmediateAction(result: RecordingResult, mode: Mode) {
        let snapshot = captureImmediateActionSnapshot(result: result, mode: mode)
        let showPreview = mode.showPreview && !result.hadDestinationOverride

        // Populate the panel with transcribed text so user can see it if they expand
        panel.populateImmediateActionText(inputSegments: snapshot.inputSegments)

        immediateActionTask = Task { @MainActor in
            let pipelineResult: SubmissionPipeline.Result
            do {
                pipelineResult = try await SubmissionPipeline.process(context: snapshot.pipelineContext)
            } catch {
                guard !Task.isCancelled else { return }
                panel.setError(error.localizedDescription)
                rebuildSessionAfterError(snapshot: snapshot)
                rewirePanelCallbacks()
                recordingIndicator.hide()
                Logger.app.error("Pipeline processing failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }

            if showPreview {
                // Preview mode: show the result and wait for confirmation
                panel.showPreview(text: pipelineResult.processedText, modeName: pipelineResult.hadExternalProcessing ? snapshot.mode.name : nil)
                pendingPreviewSnapshot = snapshot
                pendingPreviewText = pipelineResult.processedText
                immediateActionTask = nil
                recordingIndicator.hide()
                Logger.app.info("Preview shown, waiting for confirmation")
                return
            }

            // No preview — execute action immediately
            do {
                try await SubmissionPipeline.executeAction(
                    context: snapshot.pipelineContext, processedText: pipelineResult.processedText
                )
            } catch {
                guard !Task.isCancelled else { return }
                panel.setError(error.localizedDescription)
                recordHistory(
                    conversationID: snapshot.conversationID,
                    inputSegments: snapshot.inputSegments, output: pipelineResult.processedText,
                    mode: snapshot.mode
                )
                rebuildSessionAfterError(snapshot: snapshot)
                rewirePanelCallbacks()
                recordingIndicator.hide()
                Logger.app.error("Pipeline action failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }
            immediateActionTask = nil

            // Full success — dismiss and show success indicator
            panel.dismiss()
            recordingIndicator.showSuccess(destinationName: snapshot.destination.name.lowercased())

            finalizeHistory(
                snapshot: snapshot, processedText: pipelineResult.processedText,
                hadExternalProcessing: pipelineResult.hadExternalProcessing
            )
            overrides.markPipelineCompleted()
            Logger.app.info("Quick action pipeline complete")
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
        session?.previousActiveApp = snapshot.previousActiveApp
    }
}
