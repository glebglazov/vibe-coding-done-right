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
        // Check tool availability and create template modes
        settings.refreshTemplateAvailability()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        let mediaPlayback = MediaPlaybackController()
        self.mediaPlaybackController = mediaPlayback
        let history = TranscriptionHistory()
        self.transcriptionHistory = history
        let audioRecorder = AudioRecorder()
        let hotkeyManager = GlobalHotkeyManager()
        let recordingIndicator = RecordingIndicatorPanel(settings: settings, audioRecorder: audioRecorder)
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()
        let overrides = ConversationOverrides()
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings, overrides: overrides)
        let capturePanel = CapturePanel()
        let pttClipboardMonitor = ClipboardMonitor()
        let pttEscCancelManager = GlobalHotkeyManager()
        let captureCoordinator = CaptureCoordinator(
            settings: settings,
            panel: capturePanel,
            recordingIndicator: recordingIndicator,
            audioRecorder: audioRecorder,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: pttClipboardMonitor,
            escCancelManager: pttEscCancelManager,
            transcriptionHistory: history,
            overrides: overrides
        )
        self.captureCoordinator = captureCoordinator
        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: provider,
            audioRecorder: audioRecorder,
            hotkeyManager: hotkeyManager,
            mediaPlaybackController: mediaPlayback,
            recordingIndicator: recordingIndicator,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: clipboardMonitor,
            overrides: overrides
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Recording delegate closures
        coordinator.isPanelVisible = { [weak captureCoordinator] in
            captureCoordinator?.isPanelVisible ?? false
        }

        coordinator.onRecordingStarted = { [weak captureCoordinator] isFollowUp in
            captureCoordinator?.handleRecordingStarted(isFollowUp: isFollowUp)
        }

        coordinator.onTranscribing = { [weak captureCoordinator] in
            captureCoordinator?.handleTranscribing()
        }

        coordinator.onRecordingComplete = { [weak captureCoordinator] result in
            captureCoordinator?.handleRecordingComplete(result: result)
        }

        coordinator.onTranscriptionFailed = { [weak captureCoordinator] isFollowUp in
            captureCoordinator?.handleTranscriptionFailed(isFollowUp: isFollowUp)
        }

        coordinator.onRecordingCancelled = { [weak captureCoordinator] wasFollowUp, wasFreshPill in
            captureCoordinator?.handleRecordingCancelled(wasFollowUp: wasFollowUp, wasFreshPill: wasFreshPill)
        }

        coordinator.onRecordingFailed = { [weak captureCoordinator] message in
            captureCoordinator?.handleRecordingFailed(message: message)
        }

        // Dismiss mode switcher when recording starts
        coordinator.onWillStartRecording = { [weak self] in
            self?.modeSwitcherCoordinator.confirmAndHideSwitcher()
        }
        captureCoordinator.onWillStartInput = { [weak self] in
            self?.modeSwitcherCoordinator.confirmAndHideSwitcher()
        }

        // Update recording indicator labels when mode changes mid-recording
        modeSwitcherCoordinator.onModeSelected = { [weak self] _ in
            guard let self else { return }
            let labels = overrides.resolvedParameterLabels(for: self.settings.activeMode)
            recordingIndicator.updateParameterLabels(labels)
            captureCoordinator.panel.updateParameterLabels(labels)
        }

        // Update UI labels when destination override changes
        modeSwitcherCoordinator.onDestinationOverrideChanged = { [weak self] destinationID in
            self?.captureCoordinator.updateOutputDestinationOverride(destinationID)
            recordingIndicator.updateOutputDestinationOverride(destinationID)
        }

        // Wire contextual mode switcher: show mode list inside recording indicator or capture panel
        modeSwitcherCoordinator.showContextual = { [weak self] in
            guard let self else { return false }
            if recordingIndicator.isVisible {
                let vm = self.modeSwitcherCoordinator.makeViewModel(onDismiss: {
                    recordingIndicator.hideModeSwitcher()
                    self.modeSwitcherCoordinator.onContextualSwitcherHidden?()
                })
                recordingIndicator.showModeSwitcher(viewModel: vm)
                return true
            }
            if self.captureCoordinator.isModeSwitcherHostVisible {
                let vm = self.modeSwitcherCoordinator.makeViewModel(onDismiss: {
                    self.captureCoordinator.hideModeSwitcher()
                    self.modeSwitcherCoordinator.onContextualSwitcherHidden?()
                })
                self.captureCoordinator.showModeSwitcher(viewModel: vm)
                return true
            }
            return false
        }

        modeSwitcherCoordinator.dismissContextual = { [weak self] in
            guard let self else { return false }
            if recordingIndicator.isModeSwitcherVisible {
                recordingIndicator.hideModeSwitcher()
                return true
            }
            if self.captureCoordinator.isModeSwitcherVisible {
                self.captureCoordinator.hideModeSwitcher()
                return true
            }
            return false
        }

        modeSwitcherCoordinator.onContextualSwitcherShown = { [weak self] in
            self?.coordinator.suspendEscCancel()
        }

        modeSwitcherCoordinator.onContextualSwitcherHidden = { [weak self] in
            self?.coordinator.resumeEscCancel()
        }

        // Wire Escape-to-cancel: when the capture panel is locked for follow-up
        // (recording/processing in progress), Escape cancels the recording.
        captureCoordinator.panel.onCancelRecording = { [weak self] in
            self?.coordinator.cancelRecording()
        }

        // Wire cancel capture hotkey: cancels the capture (removes from history) and dismisses
        captureCoordinator.panel.onCancelCapture = { [weak captureCoordinator] in
            captureCoordinator?.cancelCapture()
        }

    }

    func initialize() async {
        checkPermissions()
        startPermissionPolling()

        // Register hotkeys immediately — don't wait for model loading.
        // RecordingCoordinator.onHotkeyDown() already guards on transcriptionProvider.isReady,
        // so hotkeys pressed before the model is ready show an appropriate error.
        if hasAccessibilityPermission {
            coordinator.setupHotkey()
            coordinator.setupToggleRecordingHotkey()
            coordinator.setupEscCancel()
            coordinator.setupDestinationHotkeys()
            modeSwitcherCoordinator.setupHotkey()
            captureCoordinator.setupHotkey()
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
                self.coordinator.setupHotkey()
                self.coordinator.setupToggleRecordingHotkey()
                self.coordinator.setupEscCancel()
                self.coordinator.setupDestinationHotkeys()
                self.modeSwitcherCoordinator.setupHotkey()
                self.captureCoordinator.setupHotkey()
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

    func openConversationFromHistory(_ conversation: Conversation) {
        let canContinue = conversation.hadExternalProcessing
            && settings.modes.contains(where: { $0.id == conversation.modeID && $0.processingType == .bashScript })
        if canContinue {
            settings.activeModeID = conversation.modeID
        }
        captureCoordinator.showFromHistory(conversation: conversation, canContinue: canContinue)
    }

    deinit {
        permissionTimer?.invalidate()
    }
}
