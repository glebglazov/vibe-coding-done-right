import Foundation
import AppKit
import OSLog

extension CaptureSession {

    // MARK: - Transcription

    /// Transcribes the recorded audio, merges captures, runs the pipeline via TextProcessor,
    /// and maps the resulting disposition to UI transitions. Cancellation-aware at every await.
    func processTranscription(audioURL: URL) async {
        do {
            // If the user recorded before the model finished loading, wait for it
            // here rather than blocking recording start. The panel already shows
            // "Transcribing..." so the user gets feedback while we wait.
            if !(await transcription.isReady) {
                panel.setPhase(.processing)
                while !(await transcription.isReady) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(100))
                }
            }

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
            // Fully drain the clipboard monitor before merging. `stopRecordingAndTranscribe`
            // cancelled the start task, but any in-flight start must be awaited here so
            // `stop()` actually cancels a running poll loop rather than no-op'ing before
            // it existed. Without this, PasteAction's own clipboard writes during the
            // subsequent `.execute` phase — and idle-phase pasteboard changes from other
            // apps — would leak into the next session's captures.
            await runState.clipboardMonitorStartTask?.value
            runState.clipboardMonitorStartTask = nil
            _ = await clipboardMonitor.stop()
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

            let mode = settings.activeMode
            let input = makeTranscriptionInput(
                text: rawText,
                runState: runState,
                mode: mode
            )

            // Populate the panel with raw text so the user can see it if they expand.
            panel.populateImmediateActionText(segments: input.inputSegments)

            processingTask = nil
            setStatus(.executing)

            await runWithTextProcessor(input: input)
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

    // MARK: - TextProcessor Integration

    /// Routes through TextProcessor and maps dispositions to UI transitions.
    private func runWithTextProcessor(input: TranscriptionInput) async {
        immediateActionTask = Task { @MainActor in
            let disposition: ProcessingDisposition
            do {
                disposition = try await self.textProcessor.process(input)
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

            switch disposition {
            case .empty:
                self.cancelHotkey.isEnabled = false
                self.panel.setError("No speech detected")
                self.scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
                self.processingTask = nil
                self.setStatus(.idle)
                self.emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)

            case .noInstruction:
                self.cancelHotkey.isEnabled = false
                self.panel.setError("No instruction detected")
                self.scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
                self.processingTask = nil
                self.setStatus(.idle)
                self.emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)

            case .preview(let handle):
                self.panel.showPreview(text: handle.displayText, modeName: handle.modeName)
                if let err = handle.aiErrorMessage {
                    self.panel.setAIProcessingError(err)
                }
                self.pendingPreview = handle
                self.immediateActionTask = nil
                self.indicator.hide()
                self.setStatus(.awaitingPreview)
                let outcomeKind: Outcome.Kind = handle.aiErrorMessage != nil ? .aiProcessingFallback : .previewShown
                self.emit(
                    outcomeKind,
                    finalText: handle.displayText,
                    destinationID: input.destination.id,
                    historyConversationID: input.conversationID
                )
                if handle.aiErrorMessage != nil {
                    Logger.app.warning("AI processing failed, showing preview with fallback text for retry")
                } else {
                    Logger.app.info("Preview shown, awaiting confirmation")
                }

            case .execute(let result):
                self.immediateActionTask = nil
                self.panel.dismiss()
                self.setStatus(.idle)
                self.indicator.showSuccess(destinationName: result.destinationName)
                self.emit(
                    .executed,
                    finalText: result.text,
                    destinationID: input.destination.id,
                    historyConversationID: input.conversationID
                )
                Logger.app.info("Capture pipeline complete")
            }
        }
    }

    // MARK: - Preview Confirmation

    func confirmPreview() {
        guard let handle = pendingPreview else { return }
        pendingPreview = nil
        panel.orderOut()
        setStatus(.executing)

        immediateActionTask = Task { @MainActor in
            do {
                try await self.textProcessor.confirm(handle)
            } catch {
                guard !Task.isCancelled else { return }
                self.panel.setError(error.localizedDescription)
                // Record partial history so the user keeps the transcription even if output failed.
                self.textProcessor.recordDismissedPreview(handle)
                self.indicator.hide()
                self.immediateActionTask = nil
                self.setStatus(.idle)
                self.emit(.failed, finalText: handle.displayText, destinationID: handle.input.destination.id, historyConversationID: handle.input.conversationID)
                Logger.app.error("Pipeline action failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }
            self.immediateActionTask = nil
            self.panel.dismiss()
            self.setStatus(.idle)
            self.indicator.showSuccess(destinationName: handle.input.destination.name.lowercased())
            self.emit(
                .executed,
                finalText: handle.displayText,
                destinationID: handle.input.destination.id,
                historyConversationID: handle.input.conversationID
            )
            Logger.app.info("Capture pipeline complete")
        }
    }

    func confirmPreviewWithDestination(_ destinationID: UUID) {
        guard let handle = pendingPreview else { return }
        pendingPreview = nil
        panel.orderOut()
        setStatus(.executing)

        let destination = settings.outputDestination(for: destinationID)

        immediateActionTask = Task { @MainActor in
            do {
                try await self.textProcessor.confirm(handle, destinationOverride: destinationID)
            } catch {
                guard !Task.isCancelled else { return }
                self.panel.setError(error.localizedDescription)
                self.textProcessor.recordDismissedPreview(handle)
                self.indicator.hide()
                self.immediateActionTask = nil
                self.setStatus(.idle)
                self.emit(.failed, finalText: handle.displayText, destinationID: destinationID, historyConversationID: handle.input.conversationID)
                Logger.app.error("Pipeline action failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }
            self.immediateActionTask = nil
            self.panel.dismiss()
            self.setStatus(.idle)
            self.indicator.showSuccess(destinationName: destination.name.lowercased())
            self.emit(
                .executed,
                finalText: handle.displayText,
                destinationID: destinationID,
                historyConversationID: handle.input.conversationID
            )
            Logger.app.info("Capture pipeline complete")
        }
    }

    // MARK: - AI Retry

    func retryAIProcessing() {
        guard let handle = pendingPreview else { return }

        panel.setPhase(.processing)

        immediateActionTask = Task { @MainActor in
            do {
                let disposition = try await self.textProcessor.retryAI(handle)
                guard !Task.isCancelled else { return }

                switch disposition {
                case .preview(let newHandle):
                    if let err = newHandle.aiErrorMessage {
                        self.panel.setAIProcessingError(err)
                    } else {
                        self.panel.showPreview(text: newHandle.displayText, modeName: newHandle.modeName)
                    }
                    self.pendingPreview = newHandle
                    self.immediateActionTask = nil
                    self.emit(
                        newHandle.aiErrorMessage != nil ? .aiProcessingFallback : .previewShown,
                        finalText: newHandle.displayText,
                        destinationID: handle.input.destination.id,
                        historyConversationID: handle.input.conversationID
                    )
                    if newHandle.aiErrorMessage != nil {
                        Logger.app.warning("AI processing retry failed: \(newHandle.aiErrorMessage!)")
                    } else {
                        Logger.app.info("AI processing retry succeeded")
                    }

                case .execute, .empty, .noInstruction:
                    break // Retry always returns preview
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.panel.setAIProcessingError(error.localizedDescription)
                self.immediateActionTask = nil
                Logger.app.warning("AI processing retry failed: \(error)")
            }
        }
    }

    // MARK: - Preview rules

    /// The rule: destination override during recording skips preview even when
    /// `mode.showPreview` is true. Named because the test name is the rule.
    nonisolated static func shouldShowPreview(mode: Mode, hadDestinationOverride: Bool) -> Bool {
        mode.showPreview && !hadDestinationOverride
    }

    // MARK: - History (for dismiss path)

    func finalizeHistoryForDismiss() {
        guard let handle = pendingPreview else { return }
        textProcessor.recordDismissedPreview(handle)
    }

    // MARK: - Input Construction

    func makeTranscriptionInput(
        text: String,
        runState: RunState,
        mode: Mode
    ) -> TranscriptionInput {
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)
        let segments = Self.makeSegments(text: text, captures: runState.captures)
        let effectiveStyle = styleProvider()
        return TranscriptionInput(
            text: text,
            mode: mode,
            captures: runState.captures,
            conversationID: runState.conversationID,
            destination: destination,
            targetAppPID: runState.previousActiveApp?.processIdentifier,
            cursorContext: runState.cursorContext,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            variableEnvironment: settings.variableEnvironment,
            aiAPIKey: settings.apiKey(for: mode.aiProvider),
            inputSegments: segments,
            hadDestinationOverride: runState.hadDestinationOverride,
            removeFillerWords: settings.removeFillerWords,
            style: effectiveStyle,
            saveResultToClipboard: mode.saveResultToClipboard,
            substitutions: substitutionStore.substitutions
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
