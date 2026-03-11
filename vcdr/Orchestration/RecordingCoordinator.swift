
import Foundation
import AppKit
import OSLog

@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case executing
        case error(String)
    }
    

    private(set) var state: State = .idle
    private let settings: AppSettings
    private let transcriptionProvider: any TranscriptionProvider
    private let audioRecorder: AudioRecorder
    private let hotkeyManager: GlobalHotkeyManager
    private let toggleRecordingHotkeyManager = GlobalHotkeyManager()
    private let escCancelManager = GlobalHotkeyManager()
    private let destinationHotkeyManager = DestinationHotkeyManager()
    /// Destination ID set by a destination hotkey during recording.
    /// Written from the CGEvent tap callback (main run loop) and read
    /// from processTranscription (@MainActor) — both on the main thread.
    private var pendingDestinationOverride: UUID?
    private let mediaPlaybackController: MediaPlaybackController
    private let recordingIndicator: RecordingIndicatorPanel
    private let captureCoordinator: CaptureCoordinator
    private let selectionCapturer: SelectionCapturer
    private let clipboardMonitor: ClipboardMonitor
    private let transcriptionHistory: TranscriptionHistory
    let overrides: ConversationOverrides

    /// Called when recording is about to start (push-to-talk down or toggle start).
    /// Used to dismiss the mode switcher overlay.
    var onWillStartRecording: (() -> Void)?

    /// Per-pipeline-run state. Non-nil while a pipeline is in progress.
    /// Cleared on completion/error/cancel.
    private var session: PipelineSession?

    private var recordingStartInstant: ContinuousClock.Instant?
    /// Tracks whether the current recording was started via toggle (vs push-to-talk)
    private var isToggleMode = false
    /// Guards against concurrent onHotkeyDown() calls racing during the async gap
    /// between state == .idle check and state = .recording assignment.
    private var isPreparingToRecord = false
    /// The in-flight processing Task, stored so it can be cancelled via cancelRecording().
    private var processingTask: Task<Void, Never>?
    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        hotkeyManager: GlobalHotkeyManager,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        captureCoordinator: CaptureCoordinator,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        transcriptionHistory: TranscriptionHistory,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.hotkeyManager = hotkeyManager
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.captureCoordinator = captureCoordinator
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
        self.transcriptionHistory = transcriptionHistory
        self.overrides = overrides
    }

    func setupHotkey() {
        let keyCode = CGKeyCode(settings.pushToTalkHotkey.keyCode)
        let modifiers = CGEventFlags(rawValue: settings.pushToTalkHotkey.modifiers)

        // Unassigned hotkey — unregister and bail
        guard settings.pushToTalkHotkey.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                self?.isToggleMode = false
                await self?.onHotkeyDown(fromHotkey: true)
            }
        }
        // Called synchronously from the CGEvent tap callback (no GCD, no Task).
        // This is critical: DispatchQueue.main.async and MainActor Tasks can be
        // delayed by seconds when the executor is stalled, but the CGEvent tap
        // callback always fires promptly on the main run loop.
        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }

        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    /// Toggle recording from UI button or toggle-recording hotkey
    func toggleRecording() {
        switch state {
        case .idle, .error:
            guard !isPreparingToRecord else { return }
            isToggleMode = true
            Task { await onHotkeyDown() }
        case .recording:
            stopRecordingAndTranscribe()
        default:
            break
        }
    }

    // MARK: - Recording Start (async — needs mic permission check)

    private func onHotkeyDown(fromHotkey: Bool = false) async {
        onWillStartRecording?()

        if case .error = state {
            state = .idle
        }

        guard state == .idle, !isPreparingToRecord else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            if state == .transcribing || state == .executing {
                recordingIndicator.buzz()
            }
            return
        }

        isPreparingToRecord = true
        defer { isPreparingToRecord = false }

        // If CapturePanel is visible, this is a recording-within-capture-view scenario.
        // Don't dismiss it — notify it that recording is starting and reuse session.
        if captureCoordinator.isPanelVisible {
            captureCoordinator.panel.lockForFollowUp()
            captureCoordinator.notifyRecordingStarted()
            if let snapshot = captureCoordinator.followUpSnapshot() {
                session = PipelineSession(followUp: snapshot)
            } else {
                session = PipelineSession()
                session?.isFollowUpFromVisibleCapturePanel = true
            }
        } else {
            // Fresh recording — clear overrides if a previous pipeline completed with them
            overrides.clearIfCompletedPipeline()
            if session == nil {
                session = PipelineSession()
            }
        }

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            session = nil
            captureCoordinator.notifyRecordingCancelled()
            captureCoordinator.panel.unlockFollowUp()
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")
        // Fire capture concurrently so it doesn't delay recording start.
        // The Cmd+C fallback path polls the clipboard for up to 100ms — we don't
        // want that blocking the recording. The result is awaited in processTranscription.
        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        session?.captureTask = Task {
            guard let text = await capturer.capture(bundleIdentifier: bundleID, pid: pid) else { return nil }
            return CapturedContext(text: text, source: .selection)
        }

        // Show indicator immediately for visual feedback — the media pause
        // and recording start below are async and can take 200-400ms.
        let isFollowUp = session?.isFollowUpFromVisibleCapturePanel ?? false
        if !isFollowUp {
            let isQuickAction = settings.activeMode.quickAction
            if isQuickAction {
                // Quick action: show RecordingIndicator (transient)
                recordingIndicator.show()
                recordingIndicator.updateOutputDestinationOverride(overrides.destinationOverride)
                recordingIndicator.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))
            } else {
                // Normal mode, panel not yet visible: show CapturePanel in pill form
                captureCoordinator.notifyRecordingStarted()
            }
        }

        if settings.audioSettings.pauseMediaDuringRecording {
            await mediaPlaybackController.pauseIfNeeded()
        }

        let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        if started {
            state = .recording
            recordingStartInstant = .now
            destinationHotkeyManager.isEnabled = true
            updateEscCancel()

            // Start monitoring clipboard for mid-recording captures (user Cmd+C).
            // The monitor waits 500ms before watching so SelectionCapturer's
            // clipboard manipulation doesn't trigger false positives.
            Task {
                await clipboardMonitor.start { [weak self] _ in
                    self?.recordingIndicator.signalClipboardCapture()
                }
            }

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .idle at that point,
            // the stop was a no-op. Cancel the recording since it contains no
            // meaningful audio (zero effective duration).
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                cancelRecording()
                return
            }
        } else {
            await mediaPlaybackController.resumeIfNeeded()
            state = .error("Failed to start recording")
            recordingIndicator.update(phase: .error, message: "Failed to start recording")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Failed to start recording")
            resetAfterDelay()
        }
    }

    // MARK: - Recording Stop (synchronous for immediate UI feedback)

    /// Stops recording synchronously and kicks off transcription in a background Task.
    /// Called from both the UI button and the hotkey-up event.
    private func stopRecordingAndTranscribe() {
        destinationHotkeyManager.isEnabled = false

        guard state == .recording else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            // Only hide the indicator if we're NOT in a processing state —
            // during transcribing/executing the indicator should stay visible
            if state != .transcribing && state != .executing {
                recordingIndicator.hide()
            }
            return
        }

        let recordingDuration = recordingStartInstant.map { $0.duration(to: .now) }
        recordingStartInstant = nil

        guard let audioURL = audioRecorder.stopRecording() else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            escCancelManager.isEnabled = false
            state = .error("No audio recorded")
            captureCoordinator.notifyRecordingCancelled()
            captureCoordinator.panel.unlockFollowUp()
            recordingIndicator.update(phase: .error, message: "No audio recorded")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        state = .transcribing
        captureCoordinator.notifyTranscribing()
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Recording stopped, transcribing...")

        // Resume media playback after stopping the mic. The delay lets CoreAudio
        // fully release the recording session so the output device is not contending
        // with an active input, which avoids degraded audio quality on resume.
        Task { @MainActor in
            try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
            await self.mediaPlaybackController.resumeIfNeeded()
        }

        processingTask = Task { @MainActor in
            let midCaptures = await self.clipboardMonitor.stop()
            let clipboardContexts = midCaptures.map { CapturedContext(text: $0, source: .clipboard) }
            self.session?.captures.append(contentsOf: clipboardContexts)
            await self.processTranscription(audioURL: audioURL, recordingDuration: recordingDuration)
        }
    }

    // MARK: - Transcription + Action (async)

    private func processTranscription(audioURL: URL, recordingDuration: Duration?) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let rawText = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try Task.checkCancellation()
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(rawText)")

            // Apply transcription-level pre-processing before any mode-specific pipeline
            let cleanedText = settings.removeFillerWords ? FillerWordRemover.remove(from: rawText) : rawText
            let text = settings.terminatorTemplateEnabled
                ? Mode.applyTerminator(cleanedText, terminator: settings.terminatorTemplate)
                : cleanedText

            try? FileManager.default.removeItem(at: audioURL)

            // Consume session state into locals for use throughout the pipeline
            var pipelineSession = session ?? PipelineSession()
            // Resolve any in-flight capture task (AX selection polling)
            if let captureTask = pipelineSession.captureTask {
                if let captured = await captureTask.value {
                    pipelineSession.captures.insert(captured, at: 0)
                }
                pipelineSession.captureTask = nil
                Logger.recording.info("Captures: \(pipelineSession.captures.count) items")
            }
            let captures = pipelineSession.captures
            let context = pipelineSession.followUpContext
            let currentTurns = pipelineSession.conversationTurns
            let activeConversationID = pipelineSession.conversationID ?? UUID()
            let wasFollowUp = pipelineSession.isFollowUpFromVisibleCapturePanel
            let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier

            // Apply destination override from hotkey pressed during recording
            let hadDestinationOverride: Bool
            if let pending = pendingDestinationOverride {
                overrides.destinationOverride = pending
                pendingDestinationOverride = nil
                hadDestinationOverride = true
            } else {
                hadDestinationOverride = false
            }
            let destinationID = overrides.resolvedDestinationID(for: settings.activeMode)
            session = nil

            guard !text.isEmpty else {
                escCancelManager.isEnabled = false
                captureCoordinator.panel.unlockFollowUp()
                if captureCoordinator.isPanelVisible {
                    // Capture panel is showing — flash error on pill, then return to idle
                    captureCoordinator.notifyTranscriptionFailed()
                    processingTask = nil
                    state = .idle
                } else {
                    captureCoordinator.notifyRecordingCancelled()
                    recordingIndicator.update(phase: .error, message: "No speech detected")
                    dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                    state = .error("No speech detected")
                    resetAfterDelay()
                }
                return
            }

            let mode = settings.activeMode
            let isQuickAction = !wasFollowUp && (mode.quickAction || hadDestinationOverride)

            if !isQuickAction {
                // Normal mode: hand off transcribed text to CaptureCoordinator
                captureCoordinator.panel.unlockFollowUp()
                captureCoordinator.populateWithTranscription(
                    text,
                    captures: captures,
                    conversationID: activeConversationID,
                    previousActiveApp: pipelineSession.previousActiveApp
                )
                recordingIndicator.hide()
                overrides.markPipelineCompleted()
                escCancelManager.isEnabled = false
                processingTask = nil
                state = .idle
                Logger.app.info("Pipeline: handed to capture view")
                return
            }

            // --- Quick action path: process and route directly ---

            let parameterValues = overrides.resolvedParameterValues(for: mode)
            let destination = settings.outputDestination(for: destinationID)

            state = .executing
            Logger.app.info("Pipeline: quick action processing")

            let result = try await TextProcessingPipeline.run(
                mode: mode,
                text: text,
                captures: captures,
                followUpContext: context,
                conversationTurns: currentTurns,
                conversationID: activeConversationID,
                parameterValues: parameterValues
            )
            let processedText = result.text
            try Task.checkCancellation()

            if destination.type == .outputPanel {
                // Quick action with output panel destination — show result in capture view
                captureCoordinator.panel.unlockFollowUp()
                captureCoordinator.showQuickActionResult(
                    input: text,
                    output: processedText,
                    captures: captures,
                    conversationID: activeConversationID,
                    previousActiveApp: pipelineSession.previousActiveApp,
                    hadExternalProcessing: result.hadExternalProcessing
                )
                recordingIndicator.hide()
            } else {
                let panelWasVisible = captureCoordinator.isPanelVisible

                // Dismiss the capture panel if it was shown during recording
                // (e.g. destination hotkey turned a normal recording into quick action)
                captureCoordinator.panel.dismiss()

                if let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: activeConversationID) {
                    try await action.execute(text: processedText)
                }
                if !panelWasVisible {
                    recordingIndicator.update(phase: .success)
                    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                }
            }

            transcriptionHistory.recordTurn(
                conversationID: activeConversationID,
                input: text,
                output: processedText,
                captures: captures,
                modeID: mode.id,
                modeName: mode.name,
                hadExternalProcessing: result.hadExternalProcessing
            )

            overrides.markPipelineCompleted()
            escCancelManager.isEnabled = false
            processingTask = nil
            state = .idle
            Logger.app.info("Pipeline: quick action complete")
        } catch is CancellationError {
            // Task was cancelled via Esc — cancelRecording() already cleaned up state
            processingTask = nil
            Logger.app.info("Processing task cancelled")
        } catch {
            escCancelManager.isEnabled = false
            processingTask = nil
            captureCoordinator.panel.unlockFollowUp()
            session = nil
            state = .error(error.localizedDescription)
            recordingIndicator.update(phase: .error, message: error.localizedDescription)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Pipeline failed: \(error)")
            resetAfterDelay()
        }
    }


    // MARK: - Toggle Recording Hotkey

    func setupToggleRecordingHotkey() {
        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned else {
            toggleRecordingHotkeyManager.unregister()
            return
        }

        toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
            self?.toggleRecording()
        }
        // Toggle mode uses only keyDown — no keyUp action needed
        toggleRecordingHotkeyManager.onKeyUp = nil

        _ = toggleRecordingHotkeyManager.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func updateToggleRecordingHotkey() {
        setupToggleRecordingHotkey()
    }

    // MARK: - Cancel Recording Hotkey

    func setupEscCancel() {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else {
            escCancelManager.isEnabled = false
            return
        }
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.cancelRecording()
        }
        escCancelManager.onKeyUp = nil
        _ = escCancelManager.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func updateCancelRecordingHotkey() {
        setupEscCancel()
    }

    // MARK: - Destination Hotkeys

    func setupDestinationHotkeys() {
        let bindings = settings.outputDestinations.map { ($0.id, $0.activationHotkey) }
        destinationHotkeyManager.onDestinationMatched = { [weak self] destinationID in
            guard let self else { return }
            self.pendingDestinationOverride = destinationID
            self.stopRecordingAndTranscribe()
        }
        destinationHotkeyManager.register(bindings: bindings)
    }

    func updateDestinationHotkeys() {
        setupDestinationHotkeys()
    }

    /// Enables the global Escape tap when recording/transcribing/executing.
    private func updateEscCancel() {
        escCancelManager.isEnabled = (state == .recording || state == .transcribing || state == .executing)
    }

    /// Temporarily disables the global Escape tap so contextual mode switcher
    /// can handle Escape via its own local event monitor without cancelling recording.
    func suspendEscCancel() {
        escCancelManager.isEnabled = false
    }

    /// Re-evaluates the global Escape tap based on current state.
    /// Call after the contextual mode switcher is dismissed.
    func resumeEscCancel() {
        updateEscCancel()
    }

    func cancelRecording() {
        // Always disable the global Escape tap first — even if the guard below
        // rejects the cancel (e.g. state is .error), we must stop swallowing Escape.
        escCancelManager.isEnabled = false
        destinationHotkeyManager.isEnabled = false
        pendingDestinationOverride = nil

        guard state == .recording || state == .transcribing || state == .executing else { return }

        // Stop clipboard monitoring (fire-and-forget since we're discarding captures)
        Task { await clipboardMonitor.stop() }

        let wasProcessing = state == .transcribing || state == .executing
        state = .idle

        if wasProcessing {
            // Cancel the in-flight transcription/action Task
            processingTask?.cancel()
            processingTask = nil
        } else {
            // Stop and discard the audio file without transcribing
            if let audioURL = audioRecorder.stopRecording() {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        Task { await mediaPlaybackController.resumeIfNeeded() }
        let wasFollowUp = captureCoordinator.panel.isLockedForFollowUp
        session = nil
        recordingStartInstant = nil
        overrides.clearAll()
        captureCoordinator.panel.unlockFollowUp()

        if captureCoordinator.isPanelVisible && !wasFollowUp {
            // Fresh recording with pill — flash cancelled icon, then dismiss
            captureCoordinator.notifyCancelled()
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.captureCoordinator.cancelCapture()
            }
        } else if captureCoordinator.isPanelVisible && wasFollowUp {
            // Follow-up recording cancelled — flash cancelled on pill, keep panel
            captureCoordinator.notifyCancelled()
        } else {
            captureCoordinator.notifyRecordingCancelled()
            recordingIndicator.showCancelled()
        }

        if wasProcessing {
            Logger.app.info("Processing cancelled via Esc")
        } else {
            Logger.app.info("Recording cancelled via Esc")
        }
    }

    // MARK: - Constants

    /// Delay after stopping the mic before resuming media playback.
    /// CoreAudio needs time to fully release the recording session so the
    /// output device is not contending with an active input — without this,
    /// the first 1-2 seconds of resumed music can sound degraded.
    private static let audioSettleDelayBeforeResume: Duration = .milliseconds(300)
    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(10)

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: Self.errorIndicatorDuration)
            if case .error = state {
                state = .idle
            }
        }
    }

    private func dismissIndicatorAfterDelay(_ duration: Duration) {
        Task {
            try? await Task.sleep(for: duration)
            // Only dismiss if still showing a terminal phase — a new recording
            // may have started and reset the phase to .recording
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }

    var isHotkeyRegistered: Bool { hotkeyManager.isRegistered }
}

extension RecordingCoordinator.State {
    var menuBarIcon: String {
        switch self {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .executing: "arrow.right.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
