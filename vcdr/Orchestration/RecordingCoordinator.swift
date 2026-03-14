
import Foundation
import AppKit
import OSLog

@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case preparingToRecord
        case recording
        case transcribing
        case executing
        case error(String)
    }

    /// Lightweight per-recording state. No conversation context — CC owns that.
    private struct RecordingRunState {
        var previousActiveApp: NSRunningApplication?
        var captureTask: Task<CapturedContext?, Never>?
        var captures: [CapturedContext] = []
        var clipboardCaptures: [CapturedContext] = []
        var destinationOverrideID: UUID?
        var isFollowUp: Bool = false

        init(isFollowUp: Bool = false) {
            self.isFollowUp = isFollowUp
        }
    }


    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                Logger.consistency.info("RC state: \(String(describing: oldValue)) → \(String(describing: self.state))")
            }
        }
    }
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
    private let selectionCapturer: SelectionCapturer
    private let clipboardMonitor: ClipboardMonitor
    let overrides: ConversationOverrides

    /// Called when recording is about to start (push-to-talk down or toggle start).
    /// Used to dismiss the mode switcher overlay.
    var onWillStartRecording: (() -> Void)?

    /// Returns whether the capture panel is currently visible.
    /// Used to determine follow-up recording behavior.
    var isPanelVisible: (() -> Bool)?

    /// Called when recording has started. isFollowUp indicates capture panel was visible.
    var onRecordingStarted: ((_ isFollowUp: Bool) -> Void)?

    /// Called when recording stopped and transcription is in progress.
    var onTranscribing: (() -> Void)?

    /// Called when transcription produced text and the full result is ready.
    var onRecordingComplete: ((RecordingResult) -> Void)?

    /// Called when transcription produced empty text (no speech detected).
    /// isFollowUp indicates whether the capture panel was visible.
    var onTranscriptionFailed: ((_ isFollowUp: Bool) -> Void)?

    /// Called when recording was cancelled by the user (Escape).
    /// wasFollowUp: panel was visible and locked. wasFreshPill: pill was shown for this recording.
    var onRecordingCancelled: ((_ wasFollowUp: Bool, _ wasFreshPill: Bool) -> Void)?

    /// Called when recording failed to start (model not ready, no audio, etc.).
    var onRecordingFailed: ((_ message: String) -> Void)?

    /// Called when the initial selection capture completes with text.
    /// Used to update the pill's clipboard badge immediately.
    var onSelectionCaptured: (() -> Void)?

    /// Called when a mid-recording clipboard capture is detected.
    /// Used to update the pill's clipboard badge counter.
    var onClipboardCaptured: (() -> Void)?

    /// Per-recording-run state. Non-nil while a recording is in progress.
    /// Cleared on completion/error/cancel.
    private var recordingRun: RecordingRunState?

    private var recordingStartInstant: ContinuousClock.Instant?
    /// Tracks whether the current recording was started via toggle (vs push-to-talk)
    private var isToggleMode = false
    /// Set when the user presses toggle again while onHotkeyDown() is mid-await.
    /// Checked after startRecording() completes to immediately stop.
    private var pendingToggleStop = false
    /// The in-flight processing Task, stored so it can be cancelled via cancelRecording().
    private var processingTask: Task<Void, Never>?
    /// The in-flight indicator dismiss Task. Stored so it can be cancelled
    /// when a new recording cycle starts, preventing a stale hide from
    /// dismissing the new recording's indicator.
    private var dismissIndicatorTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        hotkeyManager: GlobalHotkeyManager,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.hotkeyManager = hotkeyManager
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
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
            isToggleMode = true
            Task { await onHotkeyDown() }
        case .preparingToRecord:
            // User pressed toggle again while we're still setting up.
            // We can't call stopRecordingAndTranscribe() because the mic hasn't
            // started yet. Set a flag so onHotkeyDown() stops after setup.
            pendingToggleStop = true
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

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            if state == .transcribing || state == .executing {
                recordingIndicator.buzz()
            }
            return
        }

        state = .preparingToRecord
        dismissIndicatorTask?.cancel()
        defer {
            if state == .preparingToRecord {
                // If we're still preparing when the function exits, something went wrong
                // in a code path that didn't explicitly set a terminal state.
                Logger.app.error("onHotkeyDown exited while still in .preparingToRecord — resetting to .idle")
                state = .idle
            }
        }

        let isFollowUp = isPanelVisible?() ?? false
        recordingRun = RecordingRunState(isFollowUp: isFollowUp)

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            pendingToggleStop = false
            state = .error("Model still loading...")
            recordingRun = nil
            onRecordingFailed?("Model still loading...")
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        // Consistency: panel lock should not already be active when starting a fresh non-follow-up recording
        if !isFollowUp, let checkPanel = isPanelVisible, checkPanel() {
            Logger.consistency.warning("onRecordingStarted(isFollowUp=false) but panel is already visible — potential stale panel from previous cycle")
        }

        // Notify CC that recording started — CC handles panel lock/pill display
        onRecordingStarted?(isFollowUp)

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        recordingRun?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")

        // Snapshot clipboard changeCount BEFORE SelectionCapturer runs.
        // The capturer's clipboard save-copy-restore cycle bumps changeCount
        // multiple times — the clipboard monitor uses this baseline to skip them.
        let clipboardBaseline = NSPasteboard.general.changeCount

        // Fire capture concurrently so it doesn't delay recording start.
        // The Cmd+C fallback path polls the clipboard for up to 100ms — we don't
        // want that blocking the recording. The result is awaited in processTranscription.
        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        recordingRun?.captureTask = Task {
            guard let text = await capturer.capture(bundleIdentifier: bundleID, pid: pid) else { return nil }
            return CapturedContext(text: text, source: .selection)
        }

        // Signal the pill as soon as the capture task completes with a result,
        // so the clipboard badge appears immediately — not after transcription.
        Task { @MainActor [weak self] in
            guard let captured = await self?.recordingRun?.captureTask?.value,
                  captured != nil else { return }
            self?.onSelectionCaptured?()
        }

        // Show recording indicator for quick action mode only (CC shows pill for normal mode)
        if !isFollowUp {
            let isQuickAction = settings.activeMode.quickAction
            if isQuickAction {
                recordingIndicator.show()
            }
            // Normal mode non-follow-up: onRecordingStarted already told CC to show pill
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
            // Pass the pre-capture baseline so SelectionCapturer's clipboard
            // manipulation is ignored regardless of timing.
            Task {
                await clipboardMonitor.start(baselineChangeCount: clipboardBaseline) { [weak self] _ in
                    self?.recordingIndicator.signalClipboardCapture()
                    self?.onClipboardCaptured?()
                }
            }

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .preparingToRecord
            // at that point, the stop was a no-op. Cancel the recording since it
            // contains no meaningful audio (zero effective duration).
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                cancelRecording()
                return
            }

            // Toggle mode: check if user pressed toggle again during await.
            // pendingToggleStop is set by toggleRecording() when it sees
            // .preparingToRecord and can't call stopRecordingAndTranscribe() yet.
            if pendingToggleStop {
                pendingToggleStop = false
                stopRecordingAndTranscribe()
                return
            }
        } else {
            pendingToggleStop = false
            await mediaPlaybackController.resumeIfNeeded()
            state = .error("Failed to start recording")
            onRecordingFailed?("Failed to start recording")
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
            // Only hide the indicator if we're NOT in an active state —
            // during preparing/transcribing/executing the indicator should stay visible
            if state != .preparingToRecord && state != .transcribing && state != .executing {
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
            onRecordingFailed?("No audio recorded")
            recordingIndicator.update(phase: .error, message: "No audio recorded")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        state = .transcribing
        onTranscribing?()
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
            self.recordingRun?.clipboardCaptures = clipboardContexts
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

            let cleanedText = settings.removeFillerWords ? FillerWordRemover.remove(from: rawText) : rawText
            let text = settings.terminatorTemplateEnabled
                ? Mode.applyTerminator(cleanedText, terminator: settings.terminatorTemplate)
                : cleanedText

            try? FileManager.default.removeItem(at: audioURL)

            // Resolve captures from recording run
            var run = recordingRun ?? RecordingRunState()
            if let captureTask = run.captureTask {
                if let captured = await captureTask.value {
                    run.captures.insert(captured, at: 0)
                }
                run.captureTask = nil
                Logger.recording.info("Captures: \(run.captures.count) items")
            }
            run.captures.append(contentsOf: run.clipboardCaptures)

            // Apply destination override from hotkey pressed during recording
            let hadDestinationOverride: Bool
            if let pending = pendingDestinationOverride {
                pendingDestinationOverride = nil
                hadDestinationOverride = true
                run.destinationOverrideID = pending
            } else {
                hadDestinationOverride = false
            }

            let isFollowUp = run.isFollowUp
            recordingRun = nil

            guard !text.isEmpty else {
                escCancelManager.isEnabled = false
                onTranscriptionFailed?(isFollowUp)
                processingTask = nil
                state = .idle
                return
            }

            // Emit the result — CC decides what to do with it
            let result = RecordingResult(
                text: text,
                captures: run.captures,
                previousActiveApp: run.previousActiveApp,
                destinationOverrideID: run.destinationOverrideID,
                hadDestinationOverride: hadDestinationOverride,
                isFollowUp: isFollowUp
            )

            escCancelManager.isEnabled = false
            processingTask = nil
            state = .idle
            // Don't hide recordingIndicator here — CC's handler manages the indicator
            // lifecycle (it stays visible during quick action pipeline processing).
            onRecordingComplete?(result)
            Logger.app.info("Pipeline: result emitted to handler")

        } catch is CancellationError {
            processingTask = nil
            Logger.app.info("Processing task cancelled")
        } catch {
            escCancelManager.isEnabled = false
            processingTask = nil
            recordingRun = nil
            state = .error(error.localizedDescription)
            onRecordingFailed?(error.localizedDescription)
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
        escCancelManager.isEnabled = (state == .preparingToRecord || state == .recording || state == .transcribing || state == .executing)
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
        pendingToggleStop = false

        guard state == .preparingToRecord || state == .recording || state == .transcribing || state == .executing else { return }

        // Stop clipboard monitoring (fire-and-forget since we're discarding captures)
        Task { await clipboardMonitor.stop() }

        let wasProcessing = state == .transcribing || state == .executing
        let wasPreparing = state == .preparingToRecord
        state = .idle

        if wasProcessing {
            processingTask?.cancel()
            processingTask = nil
        } else if !wasPreparing {
            // Only stop audio if we actually started recording
            if let audioURL = audioRecorder.stopRecording() {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        Task { await mediaPlaybackController.resumeIfNeeded() }

        let wasFollowUp = recordingRun?.isFollowUp ?? false
        recordingRun = nil
        recordingStartInstant = nil
        overrides.clearAll()

        onRecordingCancelled?(wasFollowUp, !wasFollowUp)

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
        dismissIndicatorTask?.cancel()
        dismissIndicatorTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
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
        case .preparingToRecord: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .executing: "arrow.right.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
