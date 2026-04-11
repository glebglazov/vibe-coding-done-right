import Foundation
import AppKit
import OSLog

extension CaptureSession {

    // MARK: - Snapshot

    /// Bundles everything a submission needs at the moment of capture: the pipeline
    /// context, mode, input segments for history, conversation ID, previous active
    /// app (for focus restoration), and the resolved destination.
    struct SubmissionSnapshot {
        let pipelineContext: SubmissionPipeline.Context
        let mode: Mode
        let inputSegments: [InputSegment]
        let conversationID: UUID
        let previousActiveApp: NSRunningApplication?
        let destination: OutputDestination
    }

    // MARK: - Transcription

    /// Transcribes the recorded audio, merges captures, runs the pipeline, and either
    /// shows a preview or executes the action. Cancellation-aware at every await.
    func processTranscription(audioURL: URL) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let rawText = try await transcription.transcribe(audioFileURL: audioURL)
            try Task.checkCancellation()
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(rawText)")

            try? FileManager.default.removeItem(at: audioURL)

            // Absorb the selection capture task's result into the run's captures list.
            var runState = run ?? RunState()
            if let captureTask = runState.captureTask {
                if let captured = await captureTask.value {
                    runState.captures.insert(captured, at: 0)
                }
                runState.captureTask = nil
            }
            // Merge accumulated clipboard captures from the clipboard monitor.
            runState.captures.append(contentsOf: accumulatedClipboardCaptures)
            accumulatedClipboardCaptures = []
            Logger.recording.info("Captures: \(runState.captures.count) items")

            // Consume a destination override smuggled in by the destination hotkey.
            if let override = runState.destinationOverrideID {
                runState.hadDestinationOverride = true
                overrides.destinationOverride = override
            }

            run = nil

            guard !rawText.isEmpty else {
                cancelHotkey.isEnabled = false
                panel.setError("No speech detected")
                scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
                processingTask = nil
                setStatus(.idle)
                emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
                return
            }

            let mode = settings.activeMode
            let snapshot = makeSubmissionSnapshot(
                text: rawText,
                runState: runState,
                mode: mode
            )

            // Populate the panel with raw text so the user can see it if they expand.
            panel.populateImmediateActionText(segments: snapshot.inputSegments)

            processingTask = nil
            setStatus(.executing)

            await runProcessingPipeline(
                snapshot: snapshot,
                hadDestinationOverride: runState.hadDestinationOverride
            )
        } catch is CancellationError {
            processingTask = nil
            Logger.app.info("Processing task cancelled")
        } catch {
            cancelHotkey.isEnabled = false
            processingTask = nil
            run = nil
            setStatus(.error(error.localizedDescription))
            panel.setError(error.localizedDescription)
            scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
            emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
            Logger.app.error("Pipeline failed: \(error)")
            resetErrorAfterDelay()
        }
    }

    // MARK: - Pipeline Execution

    /// Runs the submission pipeline (filler removal → structure → AI/bash → terminator).
    /// The single code path for BOTH the initial attempt and the AI retry — the two
    /// cannot drift. On AI failure this shows a preview with a retry button, whose
    /// handler re-enters this function via `retryAIProcessing()`.
    func runProcessingPipeline(snapshot: SubmissionSnapshot, hadDestinationOverride: Bool) async {
        immediateActionTask = Task { @MainActor in
            let pipelineResult: SubmissionPipeline.Result
            do {
                // Route through the session's injected AI port (tests swap it for a fake).
                pipelineResult = try await SubmissionPipeline.process(
                    context: snapshot.pipelineContext,
                    aiPort: self.ai
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.panel.setError(error.localizedDescription)
                self.indicator.hide()
                self.immediateActionTask = nil
                self.setStatus(.idle)
                self.emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
                Logger.app.error("Pipeline processing failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }

            // AI processing failed — show preview with fallback text and expose a Retry button.
            if let fallback = pipelineResult.aiProcessingFallback {
                self.panel.showPreview(text: pipelineResult.processedText, modeName: nil)
                self.panel.setAIProcessingError(fallback.errorMessage)
                self.pendingPreview = PendingPreview(
                    snapshot: snapshot,
                    processedText: pipelineResult.processedText,
                    aiRetryStructuredText: fallback.structuredText
                )
                self.immediateActionTask = nil
                self.indicator.hide()
                self.setStatus(.awaitingPreview)
                self.emit(
                    .aiProcessingFallback,
                    finalText: pipelineResult.processedText,
                    destinationID: snapshot.destination.id,
                    historyConversationID: snapshot.conversationID
                )
                Logger.app.warning("AI processing failed, showing preview with fallback text for retry")
                return
            }

            if Self.shouldShowPreview(mode: snapshot.mode, hadDestinationOverride: hadDestinationOverride) {
                self.panel.showPreview(
                    text: pipelineResult.processedText,
                    modeName: pipelineResult.hadExternalProcessing ? snapshot.mode.name : nil
                )
                self.pendingPreview = PendingPreview(
                    snapshot: snapshot,
                    processedText: pipelineResult.processedText,
                    aiRetryStructuredText: nil
                )
                self.immediateActionTask = nil
                self.indicator.hide()
                self.setStatus(.awaitingPreview)
                self.emit(
                    .previewShown,
                    finalText: pipelineResult.processedText,
                    destinationID: snapshot.destination.id,
                    historyConversationID: snapshot.conversationID
                )
                Logger.app.info("Preview shown, awaiting confirmation")
                return
            }

            // No preview — execute the action immediately.
            await self.executeAction(
                snapshot: snapshot,
                processedText: pipelineResult.processedText,
                hadExternalProcessing: pipelineResult.hadExternalProcessing
            )
        }
    }

    /// Executes the destination action (paste/copy/bash) and finalizes history.
    func executeAction(
        snapshot: SubmissionSnapshot,
        processedText: String,
        hadExternalProcessing: Bool
    ) async {
        do {
            try await SubmissionPipeline.executeAction(
                context: snapshot.pipelineContext,
                processedText: processedText
            )
        } catch {
            guard !Task.isCancelled else { return }
            panel.setError(error.localizedDescription)
            // Record partial history so the user keeps the transcription even if output failed.
            recordHistory(
                conversationID: snapshot.conversationID,
                inputSegments: snapshot.inputSegments,
                output: processedText,
                mode: snapshot.mode
            )
            indicator.hide()
            immediateActionTask = nil
            setStatus(.idle)
            emit(.failed, finalText: processedText, destinationID: snapshot.destination.id, historyConversationID: snapshot.conversationID)
            Logger.app.error("Pipeline action failed: \(error)")
            return
        }

        guard !Task.isCancelled else { return }
        immediateActionTask = nil

        panel.dismiss()
        indicator.showSuccess(destinationName: snapshot.destination.name.lowercased())

        finalizeHistory(
            snapshot: snapshot,
            processedText: processedText,
            hadExternalProcessing: hadExternalProcessing
        )
        overrides.markPipelineCompleted()
        setStatus(.idle)
        emit(
            .executed,
            finalText: processedText,
            destinationID: snapshot.destination.id,
            historyConversationID: snapshot.conversationID
        )
        Logger.app.info("Capture pipeline complete")
    }

    // MARK: - Preview rules

    /// The rule: destination override during recording skips preview even when
    /// `mode.showPreview` is true. Named because the test name is the rule.
    nonisolated static func shouldShowPreview(mode: Mode, hadDestinationOverride: Bool) -> Bool {
        mode.showPreview && !hadDestinationOverride
    }

    // MARK: - Preview Confirmation

    func confirmPreview() {
        guard let pending = pendingPreview else { return }
        let snapshot = pending.snapshot
        let processedText = pending.processedText
        pendingPreview = nil
        panel.orderOut()
        setStatus(.executing)

        immediateActionTask = Task { @MainActor in
            await self.executeAction(
                snapshot: snapshot,
                processedText: processedText,
                hadExternalProcessing: snapshot.mode.processingType != .none
            )
        }
    }

    func confirmPreviewWithDestination(_ destinationID: UUID) {
        guard let pending = pendingPreview else { return }
        let original = pending.snapshot
        let processedText = pending.processedText

        overrides.destinationOverride = destinationID
        let destination = settings.outputDestination(for: destinationID)
        let overriddenContext = SubmissionPipeline.Context(
            text: original.pipelineContext.text,
            mode: original.mode,
            captures: original.pipelineContext.captures,
            conversationID: original.conversationID,
            parameterValues: original.pipelineContext.parameterValues,
            variableEnvironment: original.pipelineContext.variableEnvironment,
            destination: destination,
            targetAppPID: original.pipelineContext.targetAppPID,
            saveResultToClipboard: original.mode.saveResultToClipboard,
            removeFillerWords: original.pipelineContext.removeFillerWords,
            terminatorTemplateEnabled: original.pipelineContext.terminatorTemplateEnabled,
            terminatorTemplate: original.pipelineContext.terminatorTemplate,
            style: original.pipelineContext.style
        )
        let overriddenSnapshot = SubmissionSnapshot(
            pipelineContext: overriddenContext,
            mode: original.mode,
            inputSegments: original.inputSegments,
            conversationID: original.conversationID,
            previousActiveApp: original.previousActiveApp,
            destination: destination
        )
        pendingPreview = nil
        panel.orderOut()
        setStatus(.executing)

        immediateActionTask = Task { @MainActor in
            await self.executeAction(
                snapshot: overriddenSnapshot,
                processedText: processedText,
                hadExternalProcessing: overriddenSnapshot.mode.processingType != .none
            )
        }
    }

    // MARK: - AI Retry

    /// Retries the failed AI call by replaying the exact same structured text
    /// through the AI port. Both the initial call and the retry share the same
    /// port, so there is no way for them to drift.
    func retryAIProcessing() {
        guard let pending = pendingPreview,
              let structured = pending.aiRetryStructuredText else { return }

        let snapshot = pending.snapshot
        panel.setPhase(.processing)

        immediateActionTask = Task { @MainActor in
            do {
                var processedText = try await self.ai.process(
                    structuredText: structured,
                    mode: snapshot.mode,
                    variableEnvironment: snapshot.pipelineContext.variableEnvironment
                )
                guard !Task.isCancelled else { return }

                // Apply style transformation after AI processing (before terminator)
                processedText = StyleTransformer.transform(
                    processedText,
                    using: snapshot.pipelineContext.style.staticRules
                )

                if snapshot.pipelineContext.terminatorTemplateEnabled {
                    processedText = Mode.applyTerminator(
                        processedText,
                        terminator: snapshot.pipelineContext.terminatorTemplate
                    )
                }
                self.panel.showPreview(text: processedText, modeName: snapshot.mode.name)
                self.pendingPreview = PendingPreview(
                    snapshot: snapshot,
                    processedText: processedText,
                    aiRetryStructuredText: nil
                )
                self.immediateActionTask = nil
                self.emit(
                    .previewShown,
                    finalText: processedText,
                    destinationID: snapshot.destination.id,
                    historyConversationID: snapshot.conversationID
                )
                Logger.app.info("AI processing retry succeeded")
            } catch {
                guard !Task.isCancelled else { return }
                self.panel.setAIProcessingError(error.localizedDescription)
                self.immediateActionTask = nil
                Logger.app.warning("AI processing retry failed: \(error)")
            }
        }
    }

    // MARK: - History

    func finalizeHistory(snapshot: SubmissionSnapshot, processedText: String, hadExternalProcessing: Bool) {
        let output = hadExternalProcessing ? processedText : nil
        recordHistory(
            conversationID: snapshot.conversationID,
            inputSegments: snapshot.inputSegments,
            output: output,
            mode: snapshot.mode
        )
    }

    func recordHistory(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        mode: Mode
    ) {
        SubmissionPipeline.recordHistory(
            history: history,
            conversationID: conversationID,
            inputSegments: inputSegments,
            output: output,
            modeID: mode.id,
            modeName: mode.name
        )
    }

    // MARK: - Snapshot construction

    private func makeSubmissionSnapshot(
        text: String,
        runState: RunState,
        mode: Mode
    ) -> SubmissionSnapshot {
        let conversationID = runState.conversationID
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        let segments = Self.makeSegments(text: text, captures: runState.captures)
        let effectiveStyle = styleProvider()
        return SubmissionSnapshot(
            pipelineContext: .init(
                text: text,
                mode: mode,
                captures: runState.captures,
                conversationID: conversationID,
                parameterValues: overrides.resolvedParameterValues(for: mode),
                variableEnvironment: settings.variableEnvironment,
                destination: destination,
                targetAppPID: runState.previousActiveApp?.processIdentifier,
                saveResultToClipboard: mode.saveResultToClipboard,
                removeFillerWords: settings.removeFillerWords,
                terminatorTemplateEnabled: settings.terminatorTemplateEnabled,
                terminatorTemplate: settings.terminatorTemplate,
                style: effectiveStyle
            ),
            mode: mode,
            inputSegments: segments,
            conversationID: conversationID,
            previousActiveApp: runState.previousActiveApp,
            destination: destination
        )
    }

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
}

