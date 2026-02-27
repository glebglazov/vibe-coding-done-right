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
    private let selectionCapturer: SelectionCapturer
    private let transcriptionHistory: TranscriptionHistory

    /// Temporary output destination override set via mode switcher.
    /// Cleared after one transcription completes (or on error/cancel).
    var outputDestinationOverride: UUID?

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?
    private var recordingStartInstant: ContinuousClock.Instant?
    /// Tracks whether the current recording was started via toggle (vs push-to-talk)
    private var isToggleMode = false
    /// Guards against concurrent onHotkeyDown() calls racing during the async gap
    /// between state == .idle check and state = .recording assignment.
    private var isPreparingToRecord = false

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        hotkeyManager: GlobalHotkeyManager,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        transcriptionHistory: TranscriptionHistory
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.hotkeyManager = hotkeyManager
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
        self.transcriptionHistory = transcriptionHistory
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

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        previousActiveApp = NSWorkspace.shared.frontmostApplication
        capturedSelection = selectionCapturer.capture()

        if settings.audioSettings.pauseMediaDuringRecording {
            await mediaPlaybackController.pauseIfNeeded()
        }

        let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        if started {
            state = .recording
            recordingStartInstant = .now
            escCancelManager.isEnabled = true
            recordingIndicator.show(withBorder: isToggleMode)
            Logger.app.info("Recording started (toggle=\(self.isToggleMode))")

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .idle at that point,
            // the stop was a no-op. Check isHotkeyActive to catch this race condition.
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                stopRecordingAndTranscribe()
            }
        } else {
            await mediaPlaybackController.resumeIfNeeded()
            escCancelManager.isEnabled = false
            state = .error("Failed to start recording")
            recordingIndicator.show()
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

        escCancelManager.isEnabled = false

        let recordingDuration = recordingStartInstant.map { $0.duration(to: .now) }
        recordingStartInstant = nil

        guard let audioURL = audioRecorder.stopRecording() else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            state = .error("No audio recorded")
            recordingIndicator.update(phase: .error, message: "No audio recorded")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        state = .transcribing
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Push-to-talk: transcribing...")

        // Resume media playback after stopping the mic. The delay lets CoreAudio
        // fully release the recording session so the output device is not contending
        // with an active input, which avoids degraded audio quality on resume.
        Task { @MainActor in
            try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
            await self.mediaPlaybackController.resumeIfNeeded()
        }

        Task { @MainActor in await self.processTranscription(audioURL: audioURL, recordingDuration: recordingDuration) }
    }

    // MARK: - Transcription + Action (async)

    private func processTranscription(audioURL: URL, recordingDuration: Duration?) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(text)")

            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                capturedSelection = nil
                outputDestinationOverride = nil
                state = .error("No speech detected")
                recordingIndicator.update(phase: .error, message: "No speech detected")
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                resetAfterDelay()
                return
            }

            let mode = settings.activeMode
            let selection = capturedSelection
            capturedSelection = nil

            // Step 1: Pre-processing (terminator, system prompt, captured selection)
            let preprocessedText = mode.applyPreProcessing(text, capturedSelection: selection)

            // Step 2: Processing (optional bash script)
            let processedText: String
            switch mode.processingType {
            case .none:
                processedText = preprocessedText
            case .bashScript:
                processedText = try await BashRunner.run(
                    command: mode.processingCommand,
                    text: preprocessedText
                )
            }

            state = .executing
            Logger.app.info("Pipeline: executing output action")

            // Step 3: Output (paste or bash script destination)
            let action = makeOutputAction()
            try await action.execute(text: processedText)

            // Record in history (raw transcription text, before any transforms)
            let durationSeconds = recordingDuration.map {
                Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
            } ?? 0
            let record = TranscriptionRecord(
                text: text,
                modelName: transcriptionProvider.name,
                recordingDuration: durationSeconds,
                actionResult: nil,
                capturedSelection: selection
            )
            transcriptionHistory.addRecord(record)

            state = .idle
            recordingIndicator.update(phase: .success)
            dismissIndicatorAfterDelay(Self.successIndicatorDuration)
            Logger.app.info("Pipeline: complete")
        } catch {
            capturedSelection = nil
            outputDestinationOverride = nil
            state = .error(error.localizedDescription)
            recordingIndicator.update(phase: .error, message: error.localizedDescription)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Pipeline failed: \(error)")
            resetAfterDelay()
        }
    }

    private func makeOutputAction() -> any PostTranscriptionAction {
        let mode = settings.activeMode
        let targetPID = previousActiveApp?.processIdentifier

        // Use temporary override if set, otherwise mode's default destination
        let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
        outputDestinationOverride = nil

        let destination = settings.outputDestination(for: destinationID)

        switch destination.type {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bashScript:
            return OutputBashAction(
                name: destination.name,
                commandTemplate: destination.bashCommand
            )
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

    // MARK: - Esc Cancel Suspend/Resume

    /// Temporarily disables the Escape-to-cancel tap so another panel (e.g. mode switcher)
    /// can handle Escape via its own NSEvent monitor.
    func suspendEscCancel() {
        escCancelManager.isEnabled = false
    }

    /// Re-enables the Escape-to-cancel tap, but only while actively recording.
    func resumeEscCancel() {
        guard state == .recording else { return }
        escCancelManager.isEnabled = true
    }

    // MARK: - Esc Cancel

    private static let escapeKeyCode: CGKeyCode = 53
    private static let cancelledIndicatorDisplayDuration: Duration = .seconds(1)

    func setupEscCancel() {
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.cancelRecording()
        }
        escCancelManager.onKeyUp = nil

        _ = escCancelManager.register(keyCode: Self.escapeKeyCode, modifiers: [])
    }

    private func cancelRecording() {
        guard state == .recording else { return }

        escCancelManager.isEnabled = false
        state = .idle

        // Stop and discard the audio file without transcribing
        if let audioURL = audioRecorder.stopRecording() {
            try? FileManager.default.removeItem(at: audioURL)
        }

        Task { await mediaPlaybackController.resumeIfNeeded() }
        capturedSelection = nil
        outputDestinationOverride = nil
        recordingStartInstant = nil

        recordingIndicator.showCancelled()
        Logger.app.info("Recording cancelled via Esc")
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

    var menuBarIcon: String {
        switch state {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .executing: "arrow.right.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
