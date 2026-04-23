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

        // Don't gate on model readiness — start audio immediately and let the
        // model finish loading in the background. If it isn't ready by stop,
        // `processTranscription` waits for it before calling transcribe.
        showPanelMinimized()

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        run?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")

        // Start audio FIRST, then kick off capture. Capture fallbacks (Layer 3 osascript
        // `set volume alert volume`) write CoreAudio HAL properties that serialize at
        // coreaudiod against our own `setSystemDefaultInputDevice`. Running capture in
        // parallel with audio start made the input-device switch wait behind Layer 3's
        // HAL writes — adding ~400ms on AX-less apps (Ghostty, Telegram). Serializing
        // audio-first means HAL is empty during our input switch. Capture then runs
        // after, doesn't affect perceived recording start, and merges at transcription
        // time in `processTranscription`.
        let started = await audio.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        guard started else {
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

        // Detached so blocking work inside the capturer (osascript Process.waitUntilExit,
        // AX round-trips) runs off MainActor — otherwise it queues ahead of UI updates
        // that happen during recording.
        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        run?.captureTask = Task.detached { [weak self] in
            let result = await capturer.capture(bundleIdentifier: bundleID, pid: pid)

            // Store cursor context immediately (will be nil if unavailable)
            await MainActor.run {
                self?.run?.cursorContext = result.cursorContext
                // Report availability to the panel for UI indicator
                let isAvailable = result.cursorContext != nil
                self?.panel.setCursorContextAvailable(isAvailable)
                Logger.recording.info("Cursor context capture: \(isAvailable ? "available" : "unavailable")")

                // Set up observer for app switches during recording
                self?.setupAppSwitchObserver(initialBundleID: bundleID)
            }

            guard let text = result.selectedText else {
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
        //
        // The task is stored on `run` so stop paths can cancel it before it reaches
        // `monitor.start()` — otherwise a short recording can stop while this task is
        // still awaiting `captureTask.value`, and `start()` would run after `stop()`,
        // leaving the monitor polling indefinitely across session boundaries.
        run?.clipboardMonitorStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let captured = await self.run?.captureTask?.value
            guard !Task.isCancelled else { return }
            if captured != nil {
                self.panel.signalClipboardCapture()
            }
            // Start clipboard monitor with a fresh baseline after SelectionCapturer finishes.
            let freshBaseline = NSPasteboard.general.changeCount
            await self.clipboardMonitor.start(baselineChangeCount: freshBaseline) { [weak self] text in
                guard let self else { return }
                // Defense in depth: only accept captures while we're actually recording.
                // A stale monitor (e.g. race with stop) must not pollute captures when
                // the session is transcribing, executing, or idle.
                guard case .recording = self.status.phase else { return }
                self.panel.signalClipboardCapture()
                self.accumulatedClipboardCaptures.append(CapturedContext(text: text, source: .clipboard))
            }
        }

        // Pause media in the background now that audio is capturing. The
        // controller stores the in-flight task and resumeIfNeeded awaits it,
        // so a very short recording can't race pause and resume.
        if settings.audioSettings.pauseMediaDuringRecording {
            media.pauseIfNeeded()
        }

        // Notify delegate that recording started
        delegate?.captureSessionDidStartRecording(self)
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

        // Notify delegate that recording stopped (before transcription begins)
        delegate?.captureSessionDidStopRecording(self)

        // Stop clipboard monitor before transcription. Cancel the pending start task
        // first so it can't race us and call `start()` after our `stop()` — previously
        // this leaked the monitor across sessions, causing PasteAction's own clipboard
        // writes and idle-phase pasteboard changes to be captured into the next run.
        // The actual `await stop()` happens at the top of `processTranscription` where
        // we're already on an async context; doing it here would require making this
        // function async.
        run?.clipboardMonitorStartTask?.cancel()

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
        run?.clipboardMonitorStartTask?.cancel()
        let startTask = run?.clipboardMonitorStartTask
        Task { [clipboardMonitor] in
            // Await the start task first so any in-flight `start()` finishes before
            // we call `stop()`; otherwise a racing start after stop re-leaks the monitor.
            await startTask?.value
            _ = await clipboardMonitor.stop()
        }
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
        run?.clipboardMonitorStartTask?.cancel()
        let startTask = run?.clipboardMonitorStartTask
        Task { [clipboardMonitor] in
            await startTask?.value
            _ = await clipboardMonitor.stop()
        }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        immediateActionTask?.cancel()
        immediateActionTask = nil

        if saveToHistory, let handle = pendingPreview {
            textProcessor.recordDismissedPreview(handle)
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
           let conversation = history.conversations.first(where: { $0.id == pending.input.conversationID }) {
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

    // MARK: - App Switch Observer

    /// Sets up an observer to detect when user switches apps during recording.
    /// If the app changes, cursor context becomes stale and the indicator updates.
    private func setupAppSwitchObserver(initialBundleID: String?) {
        guard initialBundleID != nil else {
            // If we didn't get a bundle ID initially, don't bother observing
            return
        }

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let run = self.run,
                  let currentApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let currentBundleID = currentApp.bundleIdentifier else {
                return
            }

            // Check if app changed from the one we captured context from
            if currentBundleID != initialBundleID {
                // User switched apps - context is now stale
                self.panel.setCursorContextAvailable(false)
                Logger.recording.info("User switched apps during recording - cursor context is now stale")
            }
        }

        run?.appSwitchObserver = observer
    }

    /// Removes the app switch observer if one was set up.
    private func removeAppSwitchObserver() {
        if let observer = run?.appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            run?.appSwitchObserver = nil
        }
    }
}
