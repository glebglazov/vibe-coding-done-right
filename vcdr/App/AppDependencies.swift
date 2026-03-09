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
        let outputPanel = OutputPanelPanel(audioRecorder: audioRecorder)
        self.outputPanel = outputPanel
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()
        let overrides = ConversationOverrides()
        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: provider,
            audioRecorder: audioRecorder,
            hotkeyManager: hotkeyManager,
            mediaPlaybackController: mediaPlayback,
            recordingIndicator: recordingIndicator,
            outputPanel: outputPanel,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: clipboardMonitor,
            transcriptionHistory: history,
            overrides: overrides
        )
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings, overrides: overrides)
        let pttClipboardMonitor = ClipboardMonitor()
        let pttEscCancelManager = GlobalHotkeyManager()
        self.pushToTypeCoordinator = PushToTypeCoordinator(
            settings: settings,
            recordingIndicator: recordingIndicator,
            outputPanel: outputPanel,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: pttClipboardMonitor,
            escCancelManager: pttEscCancelManager,
            transcriptionHistory: history,
            overrides: overrides
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Dismiss mode switcher and push-to-type when recording starts
        coordinator.onWillStartRecording = { [weak self] in
            self?.modeSwitcherCoordinator.confirmAndHideSwitcher()
            self?.pushToTypeCoordinator.dismissIfActive()
        }
        pushToTypeCoordinator.onWillStartInput = { [weak self] in
            self?.modeSwitcherCoordinator.confirmAndHideSwitcher()
        }

        // Update recording indicator labels when mode changes mid-recording
        modeSwitcherCoordinator.onModeSelected = { [weak self] _ in
            guard let self else { return }
            let labels = overrides.resolvedParameterLabels(for: self.settings.activeMode)
            recordingIndicator.updateParameterLabels(labels)
        }

        // Update UI labels when destination override changes
        modeSwitcherCoordinator.onDestinationOverrideChanged = { [weak self] destinationID in
            self?.pushToTypeCoordinator.updateOutputDestinationOverride(destinationID)
            recordingIndicator.updateOutputDestinationOverride(destinationID)
        }

        // Wire contextual mode switcher: show mode list inside recording indicator or push-to-type
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
            if self.pushToTypeCoordinator.isModeSwitcherHostVisible {
                let vm = self.modeSwitcherCoordinator.makeViewModel(onDismiss: {
                    self.pushToTypeCoordinator.hideModeSwitcher()
                    self.modeSwitcherCoordinator.onContextualSwitcherHidden?()
                })
                self.pushToTypeCoordinator.showModeSwitcher(viewModel: vm)
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
            if self.pushToTypeCoordinator.isModeSwitcherVisible {
                self.pushToTypeCoordinator.hideModeSwitcher()
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
            let parameterValues = overrides.resolvedParameterValues(for: mode)
            let currentTurns = outputPanel.currentTurns

            outputPanel.startProcessing(inputText: text)

            if mode.processingType == .bashScript {
                // Streaming path for bash-processed modes
                let streamResult = TextProcessingPipeline.runStreaming(
                    mode: mode,
                    text: text,
                    capturedSelection: nil,
                    followUpContext: followUpContext,
                    conversationTurns: currentTurns,
                    conversationID: conversationID,
                    parameterValues: parameterValues
                )
                outputPanel.expand()

                Task { @MainActor in
                    var accumulated = ""
                    do {
                        for try await chunk in streamResult.chunks {
                            accumulated += chunk
                            outputPanel.updateStreamingOutput(accumulated)
                        }
                        outputPanel.finishStreaming(outputText: accumulated)

                        history.recordTurn(
                            conversationID: conversationID,
                            input: text,
                            output: accumulated,
                            capturedSelection: nil,
                            modeID: mode.id,
                            modeName: mode.name,
                            hadExternalProcessing: streamResult.hadExternalProcessing
                        )
                    } catch {
                        streamResult.cancel()
                        if accumulated.isEmpty {
                            outputPanel.showProcessingError(error.localizedDescription)
                        } else {
                            // Show partial output on error
                            outputPanel.finishStreaming(outputText: accumulated)
                        }
                    }
                }
            } else {
                // Non-streaming path
                Task { @MainActor in
                    do {
                        let result = try await TextProcessingPipeline.run(
                            mode: mode,
                            text: text,
                            capturedSelection: nil,
                            followUpContext: followUpContext,
                            conversationTurns: currentTurns,
                            conversationID: conversationID,
                            parameterValues: parameterValues
                        )
                        outputPanel.finishProcessing(outputText: result.text)

                        history.recordTurn(
                            conversationID: conversationID,
                            input: text,
                            output: result.text,
                            capturedSelection: nil,
                            modeID: mode.id,
                            modeName: mode.name,
                            hadExternalProcessing: result.hadExternalProcessing
                        )
                    } catch {
                        outputPanel.showProcessingError(error.localizedDescription)
                    }
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
                coordinator.setupDestinationHotkeys()
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
                self.coordinator.setupDestinationHotkeys()
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
        let canContinue = conversation.hadExternalProcessing
            && settings.modes.contains(where: { $0.id == conversation.modeID && $0.processingType == .bashScript })
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
