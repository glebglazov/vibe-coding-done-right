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
    let outputPanel: OutputPanelPanel

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
        let recordingIndicator = RecordingIndicatorPanel(settings: settings, audioRecorder: audioRecorder)
        let outputPanel = OutputPanelPanel()
        self.outputPanel = outputPanel
        let selectionCapturer = SelectionCapturer()
        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: provider,
            audioRecorder: audioRecorder,
            hotkeyManager: hotkeyManager,
            mediaPlaybackController: mediaPlayback,
            recordingIndicator: recordingIndicator,
            outputPanel: outputPanel,
            selectionCapturer: selectionCapturer,
            transcriptionHistory: history
        )
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings)
        self.pushToTypeCoordinator = PushToTypeCoordinator(
            settings: settings,
            recordingIndicator: recordingIndicator,
            outputPanel: outputPanel,
            selectionCapturer: selectionCapturer,
            transcriptionHistory: history
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Wire parameter resolution for push-to-type
        pushToTypeCoordinator.resolveParameterValues = { [weak self] mode in
            self?.coordinator.resolvedParameterValues(for: mode) ?? [:]
        }
        pushToTypeCoordinator.resolveParameterLabels = { [weak self] mode in
            self?.coordinator.resolvedParameterLabels(for: mode)
        }

        // Wire parameter override from mode switcher to recording coordinator
        modeSwitcherCoordinator.onParameterOverride = { [weak self] parameterID, value in
            self?.coordinator.conversationParameterOverrides[parameterID] = value
        }
        modeSwitcherCoordinator.currentParameterOverrides = { [weak self] in
            self?.coordinator.conversationParameterOverrides ?? [:]
        }

        // Wire output destination override from mode switcher to both coordinators + indicator labels
        modeSwitcherCoordinator.onOutputDestinationOverride = { [weak self] destinationID in
            self?.coordinator.setOutputDestinationOverride(destinationID)
            self?.pushToTypeCoordinator.updateOutputDestinationOverride(destinationID)
            recordingIndicator.updateOutputDestinationOverride(destinationID)
        }

        // Wire Escape-to-cancel: when the output panel is locked for follow-up
        // (recording/processing in progress), Escape cancels the recording.
        outputPanel.onCancelRecording = { [weak self] in
            self?.coordinator.cancelRecording()
        }

        // Wire inline text submission from the output panel
        outputPanel.onSubmitText = { [weak self] text in
            guard let self else { return }
            let modeID = outputPanel.currentModeID ?? self.settings.activeModeID
            let mode = self.settings.modes.first(where: { $0.id == modeID }) ?? self.settings.activeMode
            let followUpContext = outputPanel.currentText
            let conversationID = outputPanel.currentConversationID ?? UUID()
            let parameterValues = self.coordinator.resolvedParameterValues(for: mode)

            outputPanel.startProcessing(inputText: text)

            Task { @MainActor in
                do {
                    let processed = try await TextProcessingPipeline.run(
                        mode: mode,
                        text: text,
                        capturedSelection: nil,
                        followUpContext: followUpContext,
                        conversationTurns: outputPanel.currentTurns,
                        conversationID: conversationID,
                        parameterValues: parameterValues
                    )
                    outputPanel.finishProcessing(outputText: processed)

                    // Record inline follow-up in history
                    history.recordTurn(
                        conversationID: conversationID,
                        input: text,
                        output: processed,
                        capturedSelection: nil,
                        modeID: mode.id,
                        modeName: mode.name
                    )
                } catch {
                    outputPanel.showProcessingError(error.localizedDescription)
                }
            }
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

    func openConversationFromHistory(_ conversation: Conversation) {
        let canContinue = settings.modes.contains(where: { $0.id == conversation.modeID && $0.canFollowUp })
        if canContinue {
            settings.activeModeID = conversation.modeID
        }
        outputPanel.showFromHistory(
            conversation: conversation,
            outputDestinations: settings.outputDestinations,
            canContinue: canContinue
        )
    }

    deinit {
        permissionTimer?.invalidate()
    }
}
