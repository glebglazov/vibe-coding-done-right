import SwiftUI
import AVFoundation
import ApplicationServices
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
    let session: CaptureSession
    let audioDeviceMonitor: AudioDeviceMonitor
    let inputLevelMonitor: InputLevelMonitor
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let mediaPlaybackController: MediaPlaybackController
    let transcriptionHistory: TranscriptionHistory
    let copyLatestCaptureHandler: CopyLatestCaptureHandler

    #if DEBUG
    let audioRecorder: AudioRecorder
    #endif

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Loading model..."
    private(set) var hasMicrophonePermission = false
    private(set) var hasAccessibilityPermission = false
    private(set) var isInitialized = false

    var needsPermissionAttention: Bool {
        !hasMicrophonePermission || !hasAccessibilityPermission
    }

    private var permissionTimer: Timer?

    /// Holds the active mode-switcher suspension token. Nilling it releases the
    /// suspension via `SuspensionToken`'s RAII deinit.
    @ObservationIgnored fileprivate var modeSwitcherSuspension: CaptureSession.SuspensionToken?

    init() {
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        let mediaPlayback = MediaPlaybackController()
        self.mediaPlaybackController = mediaPlayback
        let history = TranscriptionHistory()
        self.transcriptionHistory = history
        let audioRecorder = AudioRecorder()
        #if DEBUG
        self.audioRecorder = audioRecorder
        #endif
        let overrides = SessionOverrides()
        let recordingIndicator = RecordingIndicatorPanel(
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        )
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings, overrides: overrides)
        let capturePanel = CapturePanel()
        self.session = CaptureSession(
            settings: settings,
            history: history,
            deps: .init(
                transcription: provider,
                audio: audioRecorder,
                media: mediaPlayback,
                selectionCapturer: selectionCapturer,
                clipboardMonitor: clipboardMonitor,
                indicator: recordingIndicator,
                panel: CapturePanelAdapter(capturePanel),
                ai: AIProcessingAdapter(),
                overrides: overrides
            )
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Wire ModeSwitcherCoordinator → AppDependencies via delegate
        modeSwitcherCoordinator.delegate = self
    }

    func initialize() async {
        // Check tool availability and create template modes (async to avoid blocking main thread)
        await settings.refreshTemplateAvailability()

        // Fetch updated prompts from server in background (non-blocking)
        Task.detached {
            await PromptFetcher.refreshIfNeeded()
        }

        checkPermissions()
        isInitialized = true
        startPermissionPolling()

        // Register hotkeys immediately — don't wait for model loading.
        // `CaptureSession.toggle()` guards on transcription readiness internally,
        // so hotkeys pressed before the model is ready show an appropriate error.
        if hasAccessibilityPermission {
            session.accessibilityGranted()
            modeSwitcherCoordinator.setupHotkey()
            copyLatestCaptureHandler.setupHotkey()
        }

        do {
            // Poll the provider's init phase so the UI updates in real time
            let phasePoller = Task {
                while !Task.isCancelled {
                    let phase = await transcriptionProvider.initPhase
                    switch phase {
                    case .notStarted, .downloading:
                        initializationStatus = "Downloading model..."
                    case .compiling:
                        initializationStatus = "Compiling model..."
                    case .ready:
                        break
                    }
                    try? await Task.sleep(for: Self.phasePollingInterval)
                }
            }

            try await transcriptionProvider.initialize()
            phasePoller.cancel()

            isTranscriptionReady = true
            initializationStatus = "Ready"
            Logger.app.info("App fully initialized")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Initialization failed: \(error)")
        }
    }

    private func checkPermissions() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    // MARK: - Constants

    private static let phasePollingInterval: Duration = .milliseconds(200)
    private static let permissionPollInterval: TimeInterval = 2

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionPollInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let wasAccessible = self.hasAccessibilityPermission
            self.checkPermissions()

            // Register hotkeys as soon as accessibility is granted
            if !wasAccessible && self.hasAccessibilityPermission {
                self.session.accessibilityGranted()
                self.modeSwitcherCoordinator.setupHotkey()
                self.copyLatestCaptureHandler.setupHotkey()
                Logger.app.info("Accessibility granted, hotkeys registered")
            }

            // Stop polling once both permissions are granted
            if self.hasMicrophonePermission && self.hasAccessibilityPermission {
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    deinit {
        permissionTimer?.invalidate()
    }
}

// MARK: - ModeSwitcherCoordinatorDelegate

extension AppDependencies: ModeSwitcherCoordinatorDelegate {

    var isRecordingActive: Bool {
        if case .recording = session.status.phase { return true }
        return false
    }

    func modeSwitcherWillShow() {
        modeSwitcherSuspension = session.suspend()
    }

    func modeSwitcherDidHide() {
        modeSwitcherSuspension = nil
    }
}
