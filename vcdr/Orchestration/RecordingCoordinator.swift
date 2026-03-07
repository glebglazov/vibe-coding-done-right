
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
    private let mediaPlaybackController: MediaPlaybackController
    private let recordingIndicator: RecordingIndicatorPanel
    private let outputPanel: OutputPanelPanel
    private let selectionCapturer: SelectionCapturer
    private let transcriptionHistory: TranscriptionHistory

    /// Parameter value overrides for the current conversation.
    /// Keyed by parameter ID -> selected option value string.
    /// Set by the mode switcher, consumed by the pipeline, cleared on conversation end.
    var conversationParameterOverrides: [UUID: String] = [:]

    /// Resolves parameter labels for display (e.g. "Sonnet, English"). Returns nil if no parameters.
    func resolvedParameterLabels(for mode: Mode) -> String? {
        let labels = mode.parameters.compactMap { param -> String? in
            guard !param.options.isEmpty else { return nil }
            if let override = conversationParameterOverrides[param.id],
               let option = param.options.first(where: { $0.value == override }) {
                return option.label
            }
            return param.options.first?.label
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Resolves parameter values for the active mode: overrides take precedence, then defaults.
    func resolvedParameterValues(for mode: Mode) -> [String: String] {
        var result: [String: String] = [:]
        for parameter in mode.parameters {
            let suffix = parameter.environmentVariableSuffix
            guard !suffix.isEmpty else { continue }
            if let override = conversationParameterOverrides[parameter.id] {
                result[suffix] = override
            } else {
                result[suffix] = parameter.options.first?.value ?? ""
            }
        }
        return result
    }

    /// Per-pipeline-run state. Non-nil while a pipeline is in progress or follow-up
    /// state has been captured from the output panel. Cleared on completion/error/cancel.
    var session: PipelineSession?

    private var recordingStartInstant: ContinuousClock.Instant?
    /// Tracks whether the current recording was started via toggle (vs push-to-talk)
    private var isToggleMode = false
    /// Guards against concurrent onHotkeyDown() calls racing during the async gap
    /// between state == .idle check and state = .recording assignment.
    private var isPreparingToRecord = false
    /// The in-flight processing Task, stored so it can be cancelled via cancelRecording().
    private var processingTask: Task<Void, Never>?
    /// Whether a pipeline has completed with active parameter overrides.
    /// Used to clear next-conversation overrides on the next fresh recording.
    private var hasCompletedPipelineWithOverrides = false

    /// Gap between the bottom of the output panel and the top of the recording indicator
    private static let panelGap: CGFloat = 8

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        hotkeyManager: GlobalHotkeyManager,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        outputPanel: OutputPanelPanel,
        selectionCapturer: SelectionCapturer,
        transcriptionHistory: TranscriptionHistory
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.hotkeyManager = hotkeyManager
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.outputPanel = outputPanel
        self.selectionCapturer = selectionCapturer
        self.transcriptionHistory = transcriptionHistory
    }

    /// Sets the output destination override from the mode switcher.
    /// Creates a session if one doesn't exist yet.
    func setOutputDestinationOverride(_ id: UUID?) {
        if let id {
            if session == nil { session = PipelineSession() }
            session?.outputDestinationOverride = id
        } else {
            session?.outputDestinationOverride = nil
        }
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

        // If the output panel is visible, this is an implicit follow-up.
        // Read state without hiding so the user sees conversation history while recording.
        if let followUp = outputPanel.readFollowUpState() {
            session = PipelineSession(
                outputDestinationOverride: OutputDestination.builtInOutputPanelID,
                followUpContext: followUp.text,
                conversationTurns: followUp.turns,
                conversationID: followUp.conversationID,
                isFollowUpFromVisibleOutputPanel: true
            )
            settings.activeModeID = followUp.modeID
            recordingIndicator.updateOutputDestinationOverride(OutputDestination.builtInOutputPanelID)
            outputPanel.lockForFollowUp()
        } else {
            // Fresh recording — clear next-conversation parameter overrides
            // if a conversation already completed with overrides active
            if hasCompletedPipelineWithOverrides {
                conversationParameterOverrides = [:]
                hasCompletedPipelineWithOverrides = false
            }
            if session == nil {
                session = PipelineSession()
            }
        }

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            session = nil
            outputPanel.unlockFollowUp()
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp
        session?.capturedSelection = await selectionCapturer.capture(bundleIdentifier: frontmostApp?.bundleIdentifier)

        // Show indicator immediately for visual feedback — the media pause
        // and recording start below are async and can take 200-400ms.
        // Position below the output panel when it's a visible follow-up.
        let isFollowUp = session?.isFollowUpFromVisibleOutputPanel ?? false
        let topOffset = isFollowUp
            ? outputPanel.currentPanelHeight + Self.panelGap
            : 0
        recordingIndicator.show(topOffset: topOffset)
        recordingIndicator.updateParameterLabels(resolvedParameterLabels(for: settings.activeMode))

        if settings.audioSettings.pauseMediaDuringRecording {
            await mediaPlaybackController.pauseIfNeeded()
        }

        let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        if started {
            state = .recording
            recordingStartInstant = .now
            updateEscCancel()

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .idle at that point,
            // the stop was a no-op. Check isHotkeyActive to catch this race condition.
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                stopRecordingAndTranscribe()
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
            recordingIndicator.update(phase: .error, message: "No audio recorded")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        state = .transcribing
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Recording stopped, transcribing...")

        // Resume media playback after stopping the mic. The delay lets CoreAudio
        // fully release the recording session so the output device is not contending
        // with an active input, which avoids degraded audio quality on resume.
        Task { @MainActor in
            try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
            await self.mediaPlaybackController.resumeIfNeeded()
        }

        processingTask = Task { @MainActor in await self.processTranscription(audioURL: audioURL, recordingDuration: recordingDuration) }
    }

    // MARK: - Transcription + Action (async)

    private func processTranscription(audioURL: URL, recordingDuration: Duration?) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let rawText = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try Task.checkCancellation()
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(rawText)")

            // Apply filler word removal before any mode-specific processing
            let text = settings.removeFillerWords ? FillerWordRemover.remove(from: rawText) : rawText

            try? FileManager.default.removeItem(at: audioURL)

            // Consume session state into locals for use throughout the pipeline
            let pipelineSession = session ?? PipelineSession()
            let selection = pipelineSession.capturedSelection
            let context = pipelineSession.followUpContext
            let currentTurns = pipelineSession.conversationTurns
            // Generate a new conversation ID for fresh recordings,
            // reuse existing one for follow-ups
            let activeConversationID = pipelineSession.conversationID ?? UUID()
            let wasFollowUpFromOutputPanel = pipelineSession.isFollowUpFromVisibleOutputPanel
            let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier
            let destinationID = pipelineSession.outputDestinationOverride ?? settings.activeMode.defaultOutputDestinationID
            session = nil

            guard !text.isEmpty else {
                escCancelManager.isEnabled = false
                outputPanel.unlockFollowUp()
                state = .error("No speech detected")
                recordingIndicator.update(phase: .error, message: "No speech detected")
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                resetAfterDelay()
                return
            }

            let mode = settings.activeMode
            let parameterValues = resolvedParameterValues(for: mode)

            // Show the pending "..." turn in the output panel while processing
            if wasFollowUpFromOutputPanel {
                outputPanel.startProcessing(inputText: text)
            }

            let processedText = try await TextProcessingPipeline.run(
                mode: mode,
                text: text,
                capturedSelection: selection,
                followUpContext: context,
                conversationTurns: currentTurns,
                conversationID: activeConversationID,
                parameterValues: parameterValues
            )

            try Task.checkCancellation()
            state = .executing
            Logger.app.info("Pipeline: executing output action")

            // Step 3: Output
            let destination = settings.outputDestination(for: destinationID)

            if destination.type == .outputPanel {
                recordingIndicator.hide()
                if wasFollowUpFromOutputPanel {
                    // Update the existing output panel in-place
                    outputPanel.finishProcessing(outputText: processedText)
                    outputPanel.unlockFollowUp()
                } else {
                    outputPanel.show(
                        inputText: text,
                        text: processedText,
                        capturedSelection: selection,
                        conversationTurns: currentTurns,
                        outputDestinations: settings.outputDestinations,
                        targetAppPID: targetAppPID,
                        modeID: mode.id,
                        conversationID: activeConversationID,
                        canFollowUp: mode.canFollowUp
                    )
                }
            } else {
                outputPanel.unlockFollowUp()
                if let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: activeConversationID) {
                    try await action.execute(text: processedText)
                }
                recordingIndicator.update(phase: .success)
                dismissIndicatorAfterDelay(Self.successIndicatorDuration)
            }

            // Record in history
            transcriptionHistory.recordTurn(
                conversationID: activeConversationID,
                input: text,
                output: processedText,
                capturedSelection: selection,
                modeID: mode.id,
                modeName: mode.name
            )

            if !conversationParameterOverrides.isEmpty {
                hasCompletedPipelineWithOverrides = true
            }

            escCancelManager.isEnabled = false
            processingTask = nil
            state = .idle
            Logger.app.info("Pipeline: complete")
        } catch is CancellationError {
            // Task was cancelled via Esc — cancelRecording() already cleaned up state
            processingTask = nil
            Logger.app.info("Processing task cancelled")
        } catch {
            escCancelManager.isEnabled = false
            processingTask = nil
            if outputPanel.isLockedForFollowUp {
                outputPanel.showProcessingError(error.localizedDescription)
            }
            outputPanel.unlockFollowUp()
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

    // MARK: - Esc Cancel

    private static let escapeKeyCode: CGKeyCode = 53

    func setupEscCancel() {
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.cancelRecording()
        }
        escCancelManager.onKeyUp = nil
        _ = escCancelManager.register(keyCode: Self.escapeKeyCode, modifiers: [])
    }

    /// Enables the global Escape tap only when the recording overlay is showing
    /// without the output panel (which handles Escape via its own local monitor).
    private func updateEscCancel() {
        escCancelManager.isEnabled = (state == .recording || state == .transcribing || state == .executing)
            && !(session?.isFollowUpFromVisibleOutputPanel ?? false)
    }

    func cancelRecording() {
        // Always disable the global Escape tap first — even if the guard below
        // rejects the cancel (e.g. state is .error), we must stop swallowing Escape.
        escCancelManager.isEnabled = false

        guard state == .recording || state == .transcribing || state == .executing else { return }

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
        session = nil
        recordingStartInstant = nil
        conversationParameterOverrides = [:]
        hasCompletedPipelineWithOverrides = false
        outputPanel.unlockFollowUp()

        // showCancelled() uses stored currentTopOffset so the indicator
        // appears where the recording indicator was, then resets it to 0.
        recordingIndicator.showCancelled()
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
