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
    private let mediaPlaybackController: MediaPlaybackController
    private let recordingIndicator: RecordingIndicatorPanel
    private let selectionCapturer: SelectionCapturer

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        hotkeyManager: GlobalHotkeyManager,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.hotkeyManager = hotkeyManager
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
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

    /// Toggle recording from UI button (fully synchronous for immediate feedback)
    func toggleRecording() {
        switch state {
        case .idle, .error:
            Task { await onHotkeyDown() }
        case .recording:
            stopRecordingAndTranscribe()
        default:
            break
        }
    }

    // MARK: - Recording Start (async — needs mic permission check)

    private func onHotkeyDown(fromHotkey: Bool = false) async {
        Logger.app.debug("[onHotkeyDown] enter — fromHotkey=\(fromHotkey), state=\(String(describing: self.state))")

        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            // Buzz the indicator to signal "busy, can't start now"
            if state == .transcribing || state == .executing {
                recordingIndicator.buzz()
            }
            return
        }

        Logger.app.debug("[onHotkeyDown] awaiting transcriptionProvider.isReady")
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

        // Capture any highlighted text in the frontmost app before recording starts
        capturedSelection = selectionCapturer.capture()

        // Snapshot and pause media BEFORE starting the mic. The snapshot must
        // happen before AVAudioRecorder activates the output device (false positives),
        // and the pause must happen before the mic opens so the user doesn't hear
        // wobbly/degraded music bleeding into the first moments of recording.
        if settings.audioSettings.pauseMediaDuringRecording {
            mediaPlaybackController.snapshotAudioState()
            mediaPlaybackController.pauseIfNeeded()
        }

        Logger.app.debug("[onHotkeyDown] awaiting audioRecorder.startRecording()")
        let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        Logger.app.debug("[onHotkeyDown] startRecording returned \(started)")
        if started {
            state = .recording
            recordingIndicator.show()
            Logger.app.info("Push-to-talk: recording started")

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .idle at that point,
            // the stop was a no-op. Check isHotkeyActive to catch this race condition.
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                Logger.app.debug("[onHotkeyDown] key already released (isHotkeyActive=false), stopping")
                stopRecordingAndTranscribe()
            }
        } else {
            // Recording failed — resume media since we paused it before the attempt
            mediaPlaybackController.resumeIfNeeded()
            state = .error("Failed to start recording")
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Failed to start recording")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Push-to-talk: failed to start recording")
            resetAfterDelay()
        }
    }

    // MARK: - Recording Stop (synchronous for immediate UI feedback)

    /// Stops recording synchronously and kicks off transcription in a background Task.
    /// Called from both the UI button and the hotkey-up event.
    private func stopRecordingAndTranscribe() {
        Logger.app.debug("[stopRecordingAndTranscribe] enter — state=\(String(describing: self.state))")
        guard state == .recording else {
            Logger.app.debug("[stopRecordingAndTranscribe] state is not .recording, returning early")
            mediaPlaybackController.resumeIfNeeded()
            // Only hide the indicator if we're NOT in a processing state —
            // during transcribing/executing the indicator should stay visible
            if state != .transcribing && state != .executing {
                recordingIndicator.hide()
            }
            return
        }

        guard let audioURL = audioRecorder.stopRecording() else {
            mediaPlaybackController.resumeIfNeeded()
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
            self.mediaPlaybackController.resumeIfNeeded()
        }

        Task { @MainActor in await self.processTranscription(audioURL: audioURL) }
    }

    // MARK: - Transcription + Action (async)

    private func processTranscription(audioURL: URL) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(text)")

            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                capturedSelection = nil
                state = .error("No speech detected")
                recordingIndicator.update(phase: .error, message: "No speech detected")
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                resetAfterDelay()
                return
            }

            let mode = settings.activeMode
            let transformedText = mode.transformTranscription(text, capturedSelection: capturedSelection)
            capturedSelection = nil

            state = .executing
            Logger.app.info("Push-to-talk: executing action")

            let action = makeAction()
            try await action.execute(text: transformedText)

            state = .idle
            recordingIndicator.update(phase: .success)
            dismissIndicatorAfterDelay(Self.successIndicatorDuration)
            Logger.app.info("Push-to-talk: complete")
        } catch {
            capturedSelection = nil
            state = .error(error.localizedDescription)
            recordingIndicator.update(phase: .error, message: error.localizedDescription)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Push-to-talk failed: \(error)")
            resetAfterDelay()
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        let mode = settings.activeMode
        let targetPID = previousActiveApp?.processIdentifier
        switch mode.actionType {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bash:
            return BashAction(
                commandTemplate: mode.bashCommand,
                pasteOutput: mode.pasteScriptOutput,
                targetAppPID: targetPID
            )
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
