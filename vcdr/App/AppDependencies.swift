import SwiftUI
import AVFoundation
import ApplicationServices
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
    let coordinator: RecordingCoordinator
    let audioDeviceMonitor: AudioDeviceMonitor
    let inputLevelMonitor: InputLevelMonitor
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let captureCoordinator: CaptureCoordinator
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

    init() {
        let settings = AppSettings()
        // Tool availability is checked asynchronously after init via refreshTemplateAvailability()
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
        let recordingIndicator = RecordingIndicatorPanel(settings: settings, overrides: overrides, audioRecorder: audioRecorder)
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings, overrides: overrides)
        let capturePanel = CapturePanel()
        let captureCoordinator = CaptureCoordinator(
            settings: settings,
            panel: capturePanel,
            recordingIndicator: recordingIndicator,
            audioRecorder: audioRecorder,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: clipboardMonitor,
            transcriptionHistory: history,
            overrides: overrides
        )
        self.captureCoordinator = captureCoordinator
        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: provider,
            audioRecorder: audioRecorder,
            mediaPlaybackController: mediaPlayback,
            recordingIndicator: recordingIndicator,
            selectionCapturer: selectionCapturer,
            overrides: overrides
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Wire RecordingCoordinator → CaptureCoordinator via delegate
        coordinator.delegate = captureCoordinator

        // Dismiss mode switcher when recording starts
        captureCoordinator.onWillStartInput = { [weak self] in
            self?.modeSwitcherCoordinator.confirmAndHideSwitcher()
        }

        // Wire ModeSwitcherCoordinator → AppDependencies via delegate
        modeSwitcherCoordinator.delegate = self

        // Wire cancel capture hotkey: cancels the capture (removes from history) and dismisses
        captureCoordinator.panel.onCancelCapture = { [weak captureCoordinator] in
            captureCoordinator?.cancelCapture()
        }

    }

    func initialize() async {
        // Check tool availability and create template modes (async to avoid blocking main thread)
        await settings.refreshTemplateAvailability()

        checkPermissions()
        isInitialized = true
        startPermissionPolling()

        // Register hotkeys immediately — don't wait for model loading.
        // RecordingCoordinator.onHotkeyDown() already guards on transcriptionProvider.isReady,
        // so hotkeys pressed before the model is ready show an appropriate error.
        if hasAccessibilityPermission {
            coordinator.setupToggleRecordingHotkey()
            coordinator.setupCancelHotkey()
            coordinator.setupDestinationHotkeys()
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

            // Register hotkey as soon as accessibility is granted
            if !wasAccessible && self.hasAccessibilityPermission {
                self.coordinator.setupToggleRecordingHotkey()
                self.coordinator.setupCancelHotkey()
                self.coordinator.setupDestinationHotkeys()
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

    func modeSwitcherShouldShowContextual() -> Bool {
        if captureCoordinator.isPanelVisible && captureCoordinator.panel.isMinimized {
            // Panel is in pill state (recording/processing) — expand and show mode switcher
            let vm = modeSwitcherCoordinator.makeViewModel(onDismiss: { [weak self] in
                self?.captureCoordinator.hideModeSwitcherAndMinimize()
                self?.coordinator.resumeCancelHotkey()
            })
            captureCoordinator.showModeSwitcherOnPill(viewModel: vm)
            return true
        }
        if captureCoordinator.isModeSwitcherHostVisible {
            let vm = modeSwitcherCoordinator.makeViewModel(onDismiss: { [weak self] in
                self?.captureCoordinator.hideModeSwitcher()
                self?.coordinator.resumeCancelHotkey()
            })
            captureCoordinator.showModeSwitcher(viewModel: vm)
            return true
        }
        return false
    }

    func modeSwitcherShouldDismissContextual() -> Bool {
        if captureCoordinator.isModeSwitcherVisible {
            captureCoordinator.hideModeSwitcher()
            return true
        }
        return false
    }

    func modeSwitcherDidShowContextual() {
        coordinator.suspendCancelHotkey()
    }

    func modeSwitcherDidHideContextual() {
        coordinator.resumeCancelHotkey()
    }
}
