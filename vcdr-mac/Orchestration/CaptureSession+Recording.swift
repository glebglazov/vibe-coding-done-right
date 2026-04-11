import Foundation
import AppKit
import OSLog

extension CaptureSession {

    // MARK: - Recording Lifecycle

    /// Begins a new capture run: resets UI, captures the current selection, pauses media,
    /// starts audio capture, enables the cancel + destination hotkeys. On any failure this
    /// rolls back to `.idle` or `.error` and fires an outcome.
    func startRecording() async {
        // Cancel any residual tasks from a previous run so they can't stomp on the new one.
        immediateActionTask?.cancel()
        immediateActionTask = nil
        pillResetTask?.cancel()
        pillResetTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        indicator.cancelPendingDismiss()
        indicator.hide()

        if case .error = status.phase {
            setStatus(.idle)
        }

        guard case .idle = status.phase else {
            Logger.app.warning("toggle pressed but not idle (phase: \(String(describing: self.status.phase)))")
            if case .transcribing = status.phase {
                panel.buzz()
            }
            return
        }

        setStatus(.preparingToRecord)

        // If we bail out early we must drop back to idle — defer ensures it.
        var preparingOK = false
        defer {
            if !preparingOK, case .preparingToRecord = status.phase {
                Logger.app.error("startRecording exited while still preparing — resetting to idle")
                setStatus(.idle)
            }
        }

        run = RunState()

        guard await transcription.isReady else {
            Logger.app.warning("toggle pressed but transcription model not loaded yet")
            setStatus(.error("Model still loading..."))
            run = nil
            indicator.show()
            indicator.update(phase: .error, message: "Model still loading...")
            indicator.dismissAfterDelay(Self.errorIndicatorDuration)
            emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
            resetErrorAfterDelay()
            return
        }

        // Show the minimized capture pill immediately so the user sees feedback.
        showPanelMinimized()

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        run?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")

        // Kick off selection capture; continue starting audio in parallel.
        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        run?.captureTask = Task {
            guard let text = await capturer.capture(bundleIdentifier: bundleID, pid: pid) else {
                Logger.recording.info("Toggle-record: no selection captured")
                return nil
            }
            Logger.recording.info("Toggle-record: storing captured selection (\(text.count) chars)")
            return CapturedContext(text: text, source: .selection)
        }

        // When the selection capture finishes we flash the clipboard-capture badge and
        // start the clipboard monitor with a fresh baseline. Must happen AFTER selection
        // capture (which mutates the clipboard) — enforced sequentially by awaiting the
        // capture task BEFORE starting the monitor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captured = await self.run?.captureTask?.value
            if captured != nil {
                self.panel.signalClipboardCapture()
            }
            // Start clipboard monitor with a fresh baseline after SelectionCapturer finishes.
            let freshBaseline = NSPasteboard.general.changeCount
            await self.clipboardMonitor.start(baselineChangeCount: freshBaseline) { [weak self] text in
                self?.panel.signalClipboardCapture()
                self?.accumulatedClipboardCaptures.append(CapturedContext(text: text, source: .clipboard))
            }
        }

        if settings.audioSettings.pauseMediaDuringRecording {
            await media.pauseIfNeeded()
        }

        let started = await audio.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        guard started else {
            await media.resumeIfNeeded()
            setStatus(.error("Failed to start recording"))
            panel.setError("Failed to start recording")
            scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
            emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
            Logger.app.error("Failed to start recording")
            resetErrorAfterDelay()
            return
        }

        preparingOK = true
        setStatus(.recording)
        recordingStartInstant = .now
        destinationHotkey.isEnabled = true
        updateCancelHotkey()
    }

    /// Stops the active recording and kicks off transcription.
    func stopRecordingAndTranscribe() {
        destinationHotkey.isEnabled = false

        guard case .recording = status.phase else {
            Task { await media.resumeIfNeeded() }
            if !isTransientRecordingPhase() {
                indicator.hide()
            }
            return
        }

        recordingStartInstant = nil

        guard let audioURL = audio.stopRecording() else {
            Task { await media.resumeIfNeeded() }
            cancelHotkey.isEnabled = false
            setStatus(.error("No audio recorded"))
            panel.setError("No audio recorded")
            scheduleAutoDismiss(after: Self.pillErrorDisplayDuration)
            emit(.failed, finalText: nil, destinationID: nil, historyConversationID: nil)
            resetErrorAfterDelay()
            return
        }

        setStatus(.transcribing)
        panel.setPhase(.processing)

        // Stop clipboard monitor before transcription. We intentionally fire-and-forget:
        // the transcription `await` gives the stop task time to drain before results
        // are merged into the run. Any captures it produces have already been appended
        // to `accumulatedClipboardCaptures` via the onCapture callback.
        Task { [clipboardMonitor] in
            _ = await clipboardMonitor.stop()
        }

        Logger.app.info("Recording stopped, transcribing...")

        Task { @MainActor in
            try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
            await self.media.resumeIfNeeded()
        }

        processingTask = Task { @MainActor in
            await self.processTranscription(audioURL: audioURL)
        }
    }

    /// Cancels an in-flight recording/transcription. Safe to call from any phase.
    func cancelRecording() {
        cancelHotkey.isEnabled = false
        destinationHotkey.isEnabled = false

        let wasTranscribing = (status.phase == .transcribing)
        let wasPreparing = (status.phase == .preparingToRecord)
        let wasRecording = (status.phase == .recording)

        guard wasTranscribing || wasPreparing || wasRecording else { return }

        setStatus(.idle)

        if wasTranscribing {
            processingTask?.cancel()
            processingTask = nil
        } else if wasRecording {
            if let audioURL = audio.stopRecording() {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        Task { await media.resumeIfNeeded() }
        Task { _ = await clipboardMonitor.stop() }
        accumulatedClipboardCaptures = []

        run = nil
        recordingStartInstant = nil
        overrides.clearAll()

        immediateActionTask?.cancel()
        immediateActionTask = nil
        panel.dismiss()
        indicator.showCancelled()

        emit(.cancelled, finalText: nil, destinationID: nil, historyConversationID: nil)
        Logger.app.info("\(wasTranscribing ? "Processing cancelled" : "Recording cancelled")")
    }

    // MARK: - Preview / Capture cancellation

    /// Tear down the capture UI without cancelling recording. Used when the panel
    /// loses focus or the user dismisses the preview. Saves preview history if present.
    func dismissOverlay(saveToHistory: Bool = true) {
        Task { _ = await clipboardMonitor.stop() }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        immediateActionTask?.cancel()
        immediateActionTask = nil

        if saveToHistory, let pending = pendingPreview {
            finalizeHistory(
                snapshot: pending.snapshot,
                processedText: pending.processedText,
                hadExternalProcessing: pending.snapshot.mode.processingType != .none
            )
        }

        pendingPreview = nil
        panel.dismiss()
        indicator.showDismissed()
        run = nil
        accumulatedClipboardCaptures = []
        overrides.clearAll()
        if case .awaitingPreview = status.phase {
            setStatus(.idle)
        }
        Logger.app.info("Capture dismissed")
    }

    /// Explicit cancel from the capture UI — removes the preview's conversation from history.
    func cancelCapture() {
        cancelHotkey.isEnabled = false

        if let pending = pendingPreview,
           let conversation = history.conversations.first(where: { $0.id == pending.snapshot.conversationID }) {
            history.removeConversation(conversation)
            Logger.app.info("Capture cancelled and removed from history")
        }
        dismissOverlay(saveToHistory: false)
        indicator.showCancelled()

        // dismissOverlay only transitions to idle from .awaitingPreview.
        // When cancelling from .executing, we must explicitly go idle.
        if case .executing = status.phase {
            setStatus(.idle)
        }

        if case .idle = status.phase {
            emit(.cancelled, finalText: nil, destinationID: nil, historyConversationID: nil)
        }
    }

    // MARK: - Helpers

    func scheduleAutoDismiss(after duration: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.cancelCapture()
        }
    }

    func resetErrorAfterDelay() {
        Task { [weak self] in
            try? await Task.sleep(for: Self.errorIndicatorDuration)
            guard let self else { return }
            if case .error = self.status.phase {
                self.setStatus(.idle)
            }
        }
    }

    private func showPanelMinimized() {
        let config = PanelShowConfig(
            settings: settings,
            overrides: overrides,
            displayedTurn: nil,
            outputDestinations: settings.outputDestinations,
            initialAppName: run?.previousActiveApp?.localizedName,
            audioRecorder: audio,
            minimized: true
        )
        panel.show(config: config)
        panel.setPhase(.recording)
        panel.minimize()
    }

    private func isTransientRecordingPhase() -> Bool {
        switch status.phase {
        case .preparingToRecord, .transcribing: true
        default: false
        }
    }
}
