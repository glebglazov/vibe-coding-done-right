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
    let pushToTypeCoordinator: PushToTypeCoordinator
    let mediaPlaybackController: MediaPlaybackController
    let transcriptionHistory: TranscriptionHistory
    let copyLatestCaptureHandler: CopyLatestCaptureHandler

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Loading model..."
    private(set) var hasMicrophonePermission = false
    private(set) var hasAccessibilityPermission = false

    var needsPermissionAttention: Bool {
        !hasMicrophonePermission || !hasAccessibilityPermission
    }

    private var permissionTimer: Timer?

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
        let hotkeyManager = GlobalHotkeyManager()
        let recordingIndicator = RecordingIndicatorPanel()
        let selectionCapturer = SelectionCapturer()
        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: provider,
            audioRecorder: audioRecorder,
            hotkeyManager: hotkeyManager,
            mediaPlaybackController: mediaPlayback,
            recordingIndicator: recordingIndicator,
            selectionCapturer: selectionCapturer,
            transcriptionHistory: history
        )
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings)
        self.pushToTypeCoordinator = PushToTypeCoordinator(
            settings: settings,
            recordingIndicator: recordingIndicator,
            selectionCapturer: selectionCapturer,
            transcriptionHistory: history
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Wire output destination override from mode switcher to both coordinators
        modeSwitcherCoordinator.onOutputDestinationOverride = { [weak self] destinationID in
            self?.coordinator.outputDestinationOverride = destinationID
            self?.pushToTypeCoordinator.outputDestinationOverride = destinationID
        }

        // Suspend esc-cancel while mode switcher is open so Escape dismisses the switcher,
        // then re-enable it once the switcher closes (if still recording).
        modeSwitcherCoordinator.onPanelShow = { [weak self] in
            self?.coordinator.suspendEscCancel()
        }
        modeSwitcherCoordinator.onPanelHide = { [weak self] in
            self?.coordinator.resumeEscCancel()
        }

    }

    func initialize() async {
        checkPermissions()
        startPermissionPolling()

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
            if hasAccessibilityPermission {
                coordinator.setupHotkey()
                coordinator.setupToggleRecordingHotkey()
                coordinator.setupEscCancel()
                modeSwitcherCoordinator.setupHotkey()
                pushToTypeCoordinator.setupHotkey()
                copyLatestCaptureHandler.setupHotkey()
            }
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
                self.coordinator.setupHotkey()
                self.coordinator.setupToggleRecordingHotkey()
                self.coordinator.setupEscCancel()
                self.modeSwitcherCoordinator.setupHotkey()
                self.pushToTypeCoordinator.setupHotkey()
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
