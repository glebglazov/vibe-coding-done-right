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

    struct RecordingRunState {
        var previousActiveApp: NSRunningApplication?
        var captureTask: Task<CapturedContext?, Never>?
        var captures: [CapturedContext] = []
        var destinationOverrideID: UUID?
    }

    // MARK: - Constants

    private static let audioSettleDelayBeforeResume: Duration = .milliseconds(300)

    // MARK: - Properties

    var state: State = .idle {
        didSet {
            if oldValue != state {
                Logger.consistency.info("RC state: \(String(describing: oldValue)) → \(String(describing: self.state))")
            }
        }
    }
    let settings: AppSettings
    let transcriptionProvider: any TranscriptionProvider
    private let audioRecorder: AudioRecorder
    let toggleRecordingHotkeyManager = GlobalHotkeyManager()
    let cancelHotkeyManager = GlobalHotkeyManager()
    let destinationHotkeyManager = DestinationHotkeyManager()
    private let mediaPlaybackController: MediaPlaybackController
    let recordingIndicator: RecordingIndicatorPanel
    private let selectionCapturer: SelectionCapturer
    let overrides: SessionOverrides

    @ObservationIgnored weak var delegate: RecordingCoordinatorDelegate?

    @ObservationIgnored var pendingDestinationOverride: UUID?
    @ObservationIgnored var recordingRun: RecordingRunState?
    @ObservationIgnored private var recordingStartInstant: ContinuousClock.Instant?
    @ObservationIgnored var processingTask: Task<Void, Never>?

    // MARK: - Init

    init(
        settings: AppSettings,
        transcriptionProvider: any TranscriptionProvider,
        audioRecorder: AudioRecorder,
        mediaPlaybackController: MediaPlaybackController,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        overrides: SessionOverrides
    ) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = audioRecorder
        self.mediaPlaybackController = mediaPlaybackController
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
        self.overrides = overrides
    }

    // MARK: - Recording State Machine

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
        delegate?.recordingCoordinatorWillStartRecording()

        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            if state == .transcribing {
                delegate?.recordingCoordinatorDidRejectInput()
            }
            return
        }

        state = .preparingToRecord
        recordingIndicator.cancelPendingDismiss()
        defer {
            if state == .preparingToRecord {
                Logger.app.error("startRecording exited while still in .preparingToRecord — resetting to .idle")
                state = .idle
            }
        }

        recordingRun = RecordingRunState()

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            recordingRun = nil
            delegate?.recordingCoordinatorDidFailRecording(message: "Model still loading...")
            recordingIndicator.show()
            recordingIndicator.update(phase: .error, message: "Model still loading...")
            recordingIndicator.dismissAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        delegate?.recordingCoordinatorDidStartRecording()

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        recordingRun?.previousActiveApp = frontmostApp
        Logger.recording.info("Capturing selection from app: \(frontmostApp?.bundleIdentifier ?? "unknown")")

        let capturer = selectionCapturer
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        recordingRun?.captureTask = Task {
            guard let text = await capturer.capture(bundleIdentifier: bundleID, pid: pid) else {
                Logger.recording.info("Toggle-record: no selection captured")
                return nil
            }
            Logger.recording.info("Toggle-record: storing captured selection (\(text.count) chars): \"\(text.prefix(80))\"")
            return CapturedContext(text: text, source: .selection)
        }

        Task { @MainActor [weak self] in
            let captured = await self?.recordingRun?.captureTask?.value
            self?.delegate?.recordingCoordinatorSelectionCaptureFinished(didCapture: captured != nil)
        }

        if settings.audioSettings.pauseMediaDuringRecording {
            await mediaPlaybackController.pauseIfNeeded()
        }

        let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
        guard started else {
            await mediaPlaybackController.resumeIfNeeded()
            state = .error("Failed to start recording")
            delegate?.recordingCoordinatorDidFailRecording(message: "Failed to start recording")
            Logger.app.error("Failed to start recording")
            resetAfterDelay()
            return
        }

        state = .recording
        recordingStartInstant = .now
        destinationHotkeyManager.isEnabled = true
        updateCancelHotkey()

    }

    func stopRecordingAndTranscribe() {
        destinationHotkeyManager.isEnabled = false

        guard state == .recording else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            if state != .preparingToRecord && state != .transcribing {
                recordingIndicator.hide()
            }
            return
        }

        recordingStartInstant = nil

        guard let audioURL = audioRecorder.stopRecording() else {
            Task { await mediaPlaybackController.resumeIfNeeded() }
            cancelHotkeyManager.isEnabled = false
            state = .error("No audio recorded")
            delegate?.recordingCoordinatorDidFailRecording(message: "No audio recorded")
            resetAfterDelay()
            return
        }

        state = .transcribing
        delegate?.recordingCoordinatorDidStartTranscribing()
        Logger.app.info("Recording stopped, transcribing...")

        Task { @MainActor in
            try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
            await self.mediaPlaybackController.resumeIfNeeded()
        }

        processingTask = Task { @MainActor in
            await self.processTranscription(audioURL: audioURL)
        }
    }

    func cancelRecording() {
        cancelHotkeyManager.isEnabled = false
        destinationHotkeyManager.isEnabled = false
        pendingDestinationOverride = nil

        guard state == .preparingToRecord || state == .recording || state == .transcribing else { return }

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

        recordingRun = nil
        recordingStartInstant = nil
        overrides.clearAll()

        delegate?.recordingCoordinatorDidCancelRecording()

        if wasProcessing {
            Logger.app.info("Processing cancelled via Esc")
        } else {
            Logger.app.info("Recording cancelled via Esc")
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
