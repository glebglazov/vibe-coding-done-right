import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class PushToTypeCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = PushToTypePanel()
    private let recordingIndicator: RecordingIndicatorPanel
    private let outputPanel: OutputPanelPanel
    private let selectionCapturer: SelectionCapturer
    private let transcriptionHistory: TranscriptionHistory

    /// Per-pipeline-run state. Non-nil while a pipeline is in progress or follow-up
    /// state has been captured from the output panel. Cleared on completion/error/cancel.
    var session: PipelineSession?

    /// Resolves parameter values for a mode using the recording coordinator's overrides
    var resolveParameterValues: ((Mode) -> [String: String])?

    /// Resolves parameter labels for display (e.g. "Sonnet, English")
    var resolveParameterLabels: ((Mode) -> String?)?

    func updateOutputDestinationOverride(_ id: UUID?) {
        if let id {
            if session == nil { session = PipelineSession() }
            session?.outputDestinationOverride = id
        } else {
            session?.outputDestinationOverride = nil
        }
        panel.updateOutputDestinationOverride(id)
    }

    // MARK: - Constants

    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(10)
    /// Gap between the bottom of the output panel and the top of the push-to-type overlay
    private static let panelGap: CGFloat = 8

    init(
        settings: AppSettings,
        recordingIndicator: RecordingIndicatorPanel,
        outputPanel: OutputPanelPanel,
        selectionCapturer: SelectionCapturer,
        transcriptionHistory: TranscriptionHistory
    ) {
        self.settings = settings
        self.recordingIndicator = recordingIndicator
        self.outputPanel = outputPanel
        self.selectionCapturer = selectionCapturer
        self.transcriptionHistory = transcriptionHistory
    }

    func setupHotkey() {
        let binding = settings.pushToTypeHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Push-to-type hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.toggleOverlay()
            }
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    // MARK: - Overlay Lifecycle

    private func toggleOverlay() async {
        if panel.isVisible {
            panel.hide()
            session = nil
            outputPanel.unlockFollowUp()
            Logger.app.info("Push-to-type: overlay dismissed via hotkey")
        } else {
            // If the output panel is visible, this is an implicit follow-up.
            // Read state without hiding so the user sees conversation history while typing.
            if let followUp = outputPanel.readFollowUpState() {
                session = PipelineSession(
                    outputDestinationOverride: OutputDestination.builtInOutputPanelID,
                    followUpContext: followUp.text,
                    conversationTurns: followUp.turns,
                    conversationID: followUp.conversationID,
                    isFollowUpFromVisibleOutputPanel: true
                )
                settings.activeModeID = followUp.modeID
                recordingIndicator.updateOutputDestinationOverride(OutputDestination.builtInOutputPanelID)
                outputPanel.lockForFollowUp()
            } else if session == nil {
                session = PipelineSession()
            }
            await showOverlay()
        }
    }

    private func showOverlay() async {
        // Capture context from the frontmost app before showing the overlay
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp
        session?.capturedSelection = await selectionCapturer.capture(bundleIdentifier: frontmostApp?.bundleIdentifier)

        // When the output panel is visible, position below it and skip duplicate
        // conversation turns (the output panel already shows them).
        let isFollowUp = session?.isFollowUpFromVisibleOutputPanel ?? false
        let topOffset = isFollowUp
            ? outputPanel.currentPanelHeight + Self.panelGap
            : 0
        let overlayTurns = isFollowUp ? [] : (session?.conversationTurns ?? [])

        panel.show(
            settings: settings,
            conversationTurns: overlayTurns,
            capturedSelection: session?.capturedSelection,
            topOffset: topOffset,
            onSubmit: { [weak self] text in
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.session = nil
                self?.outputPanel.unlockFollowUp()
                Logger.app.info("Push-to-type: overlay dismissed")
            }
        )
        panel.updateParameterLabels(resolveParameterLabels?(settings.activeMode))
        Logger.app.info("Push-to-type: overlay shown")
    }

    // MARK: - Text Submission Pipeline

    private func submitText(_ text: String) {
        // Consume session state into locals for use throughout the pipeline
        let pipelineSession = session ?? PipelineSession()
        let mode = settings.activeMode
        let selection = pipelineSession.capturedSelection
        let activeConversationID = pipelineSession.conversationID ?? UUID()
        let currentTurns = pipelineSession.conversationTurns
        let context = pipelineSession.followUpContext
        let wasFollowUpFromOutputPanel = pipelineSession.isFollowUpFromVisibleOutputPanel
        let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier
        let destinationID = pipelineSession.outputDestinationOverride ?? mode.defaultOutputDestinationID
        session = nil

        if wasFollowUpFromOutputPanel {
            // Use the output panel's "..." turn as the processing indicator
            outputPanel.startProcessing(inputText: text)
        } else {
            recordingIndicator.show()
            recordingIndicator.update(phase: .processing)
        }
        Logger.app.info("Push-to-type: executing pipeline")

        Task { @MainActor in
            do {
                let parameterValues = self.resolveParameterValues?(mode) ?? [:]
                let processedText = try await TextProcessingPipeline.run(
                    mode: mode,
                    text: text,
                    capturedSelection: selection,
                    followUpContext: context,
                    conversationTurns: currentTurns,
                    conversationID: activeConversationID,
                    parameterValues: parameterValues
                )

                // Step 3: Output
                let destination = settings.outputDestination(for: destinationID)

                if destination.type == .outputPanel {
                    recordingIndicator.hide()
                    if wasFollowUpFromOutputPanel {
                        // Update the existing output panel in-place
                        outputPanel.finishProcessing(outputText: processedText)
                        outputPanel.unlockFollowUp()
                        outputPanel.makeKeyIfVisible()
                    } else {
                        outputPanel.show(
                            inputText: text,
                            text: processedText,
                            capturedSelection: selection,
                            conversationTurns: currentTurns,
                            outputDestinations: settings.outputDestinations,
                            targetAppPID: targetAppPID,
                            modeID: mode.id,
                            conversationID: activeConversationID,
                            canFollowUp: mode.canFollowUp
                        )
                    }
                } else {
                    outputPanel.unlockFollowUp()
                    if let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: activeConversationID) {
                        try await action.execute(text: processedText)
                    }
                    recordingIndicator.update(phase: .success)
                    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                }

                // Record in history
                transcriptionHistory.recordTurn(
                    conversationID: activeConversationID,
                    input: text,
                    output: processedText,
                    capturedSelection: selection,
                    modeID: mode.id,
                    modeName: mode.name
                )

                Logger.app.info("Push-to-type: complete")
            } catch {
                if wasFollowUpFromOutputPanel {
                    outputPanel.showProcessingError(error.localizedDescription)
                }
                outputPanel.unlockFollowUp()
                session = nil
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Push-to-type failed: \(error)")
            }
        }
    }

    private func dismissIndicatorAfterDelay(_ duration: Duration) {
        Task {
            try? await Task.sleep(for: duration)
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }
}
