import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case preparingToRecord
        case recording
        case transcribing
        case error(String)
    }

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
    private let toggleRecordingHotkeyManager = GlobalHotkeyManager()
    private let escCancelManager = GlobalHotkeyManager()
    private let destinationHotkeyManager = DestinationHotkeyManager()
    private var pendingDestinationOverride: UUID?
    private let mediaPlaybackController: MediaPlaybackController
    private let recordingIndicator: RecordingIndicatorPanel
    private let selectionCapturer: SelectionCapturer
    private let clipboardMonitor: ClipboardMonitor
    let overrides: ConversationOverrides

    var onWillStartRecording: (() -> Void)?

    var isPanelVisible: (() -> Bool)?

    var onRecordingStarted: ((_ isFollowUp: Bool) -> Void)?

    var onTranscribing: (() -> Void)?

    var onRecordingComplete: ((RecordingResult) -> Void)?

    var onTranscriptionFailed: ((_ isFollowUp: Bool) -> Void)?

    var onRecordingCancelled: ((_ wasFollowUp: Bool, _ wasFreshPill: Bool) -> Void)?

    var onRecordingFailed: ((_ message: String) -> Void)?

    var onSelectionCaptured: (() -> Void)?

    var onClipboardCaptured: (() -> Void)?

    private var recordingRun: RecordingRunState?

    private var recordingStartInstant: ContinuousClock.Instant?
    private var processingTask: Task<Void, Never>?
    private var dismissIndicatorTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
        self.overrides = overrides
    }

    func toggleRecording() {
        switch state {
        case .idle, .error:
            Task { await startRecording() }
        case .recording:
            stopRecordingAndTranscribe()
        default:
            break
        }
    }

    private func startRecording() async {
        onWillStartRecording?()

        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            if state == .transcribing {
                recordingIndicator.buzz()
            }
            return
        }

        state = .preparingToRecord
        dismissIndicatorTask?.cancel()
        defer {
            if state == .preparingToRecord {
                Logger.app.error("startRecording exited while still in .preparingToRecord — resetting to .idle")
                state = .idle
            }
        }

        let isFollowUp = isPanelVisible?() ?? false
        recordingRun = RecordingRunState(isFollowUp: isFollowUp)

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            recordingRun = nil
            onRecordingFailed?("Model still loading...")
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        if !isFollowUp, let checkPanel = isPanelVisible, checkPanel() {
            Logger.consistency.warning("onRecordingStarted(isFollowUp=false) but panel is already visible — potential stale panel from previous cycle")
        }

        onRecordingStarted?(isFollowUp)

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        recordingRun?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")

        let clipboardBaseline = NSPasteboard.general.changeCount

        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        recordingRun?.captureTask = Task {
            guard let text = await capturer.capture(bundleIdentifier: bundleID, pid: pid) else { return nil }
            return CapturedContext(text: text, source: .selection)
        }

        Task { @MainActor [weak self] in
            guard let captured = await self?.recordingRun?.captureTask?.value,
                  captured != nil else { return }
            self?.onSelectionCaptured?()
        }

        if !isFollowUp {
            let isQuickAction = settings.activeMode.quickAction
            if isQuickAction {
                recordingIndicator.show()
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

            Task {
                await clipboardMonitor.start(baselineChangeCount: clipboardBaseline) { [weak self] _ in
                    self?.recordingIndicator.signalClipboardCapture()
                    self?.onClipboardCaptured?()
                }
            }

        } else {
            await mediaPlaybackController.resumeIfNeeded()
            state = .error("Failed to start recording")
            onRecordingFailed?("Failed to start recording")
            recordingIndicator.update(phase: .error, message: "Failed to start recording")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Failed to start recording")
            resetAfterDelay()
        }
    }

    private func stopRecordingAndTranscribe() {
        destinationHotkeyManager.isEnabled = false

        guard state == .recording else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            if state != .preparingToRecord && state != .transcribing {
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

            var run = recordingRun ?? RecordingRunState()
            if let captureTask = run.captureTask {
                if let captured = await captureTask.value {
                    run.captures.insert(captured, at: 0)
                }
                run.captureTask = nil
                Logger.recording.info("Captures: \(run.captures.count) items")
            }
            run.captures.append(contentsOf: run.clipboardCaptures)

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

    func setupToggleRecordingHotkey() {
        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned else {
            toggleRecordingHotkeyManager.unregister()
            return
        }

        toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
            self?.toggleRecording()
        }
        toggleRecordingHotkeyManager.onKeyUp = nil

        _ = toggleRecordingHotkeyManager.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

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

    func setupDestinationHotkeys() {
        let bindings = settings.outputDestinations.map { ($0.id, $0.activationHotkey) }
        destinationHotkeyManager.onDestinationMatched = { [weak self] destinationID in
            guard let self else { return }
            self.pendingDestinationOverride = destinationID
            self.stopRecordingAndTranscribe()
        }
        destinationHotkeyManager.register(bindings: bindings)
    }

    private func updateEscCancel() {
        escCancelManager.isEnabled = (state == .preparingToRecord || state == .recording || state == .transcribing)
    }

    func suspendEscCancel() {
        escCancelManager.isEnabled = false
    }

    func resumeEscCancel() {
        updateEscCancel()
    }

    func cancelRecording() {
        escCancelManager.isEnabled = false
        destinationHotkeyManager.isEnabled = false
        pendingDestinationOverride = nil

        guard state == .preparingToRecord || state == .recording || state == .transcribing else { return }

        Task { await clipboardMonitor.stop() }

        let wasProcessing = state == .transcribing
        let wasPreparing = state == .preparingToRecord
        state = .idle

        if wasProcessing {
            processingTask?.cancel()
            processingTask = nil
        } else if !wasPreparing {
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
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }

}

extension RecordingCoordinator.State {
    var menuBarIcon: String {
        switch self {
        case .idle: "waveform.circle"
        case .preparingToRecord: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
