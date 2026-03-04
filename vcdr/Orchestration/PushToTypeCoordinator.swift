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

    /// Temporary output destination override set via mode switcher
    var outputDestinationOverride: UUID?

    /// Conversation UUID for follow-up pipeline runs.
    /// Cleared after pipeline completes.
    var conversationID: UUID?

    /// Accumulated conversation turns from previous follow-ups.
    /// Passed to the output panel so it can display the full conversation history.
    /// Cleared after one pipeline run completes (or on error).
    var conversationTurns: [ConversationTurn] = []

    /// Follow-up context from the output panel. Contains the previous capture's
    /// processed text, injected between system prompt and new input.
    /// Cleared after one pipeline run completes (or on error).
    var followUpContext: String?

    func updateOutputDestinationOverride(_ id: UUID?) {
        outputDestinationOverride = id
        panel.updateOutputDestinationOverride(id)
    }

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?
    /// True when the current submission is a follow-up triggered while the output panel was visible.
    /// The output panel stays visible and the push-to-type overlay is positioned below it.
    private var isFollowUpFromVisibleOutputPanel = false

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
            isFollowUpFromVisibleOutputPanel = false
            outputPanel.unlockFollowUp()
            Logger.app.info("Push-to-type: overlay dismissed via hotkey")
        } else {
            // If the output panel is visible, this is an implicit follow-up.
            // Read state without hiding so the user sees conversation history while typing.
            if let followUp = outputPanel.readFollowUpState() {
                followUpContext = followUp.text
                conversationTurns = followUp.turns
                conversationID = followUp.conversationID
                settings.activeModeID = followUp.modeID
                outputDestinationOverride = OutputDestination.builtInOutputPanelID
                recordingIndicator.updateOutputDestinationOverride(OutputDestination.builtInOutputPanelID)
                isFollowUpFromVisibleOutputPanel = true
                outputPanel.lockForFollowUp()
            }
            await showOverlay()
        }
    }

    private func showOverlay() async {
        // Capture context from the frontmost app before showing the overlay
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        capturedSelection = await selectionCapturer.capture(bundleIdentifier: previousActiveApp?.bundleIdentifier)

        // When the output panel is visible, position below it and skip duplicate
        // conversation turns (the output panel already shows them).
        let topOffset = isFollowUpFromVisibleOutputPanel
            ? outputPanel.currentPanelHeight + Self.panelGap
            : 0
        let overlayTurns = isFollowUpFromVisibleOutputPanel ? [] : conversationTurns

        panel.show(
            settings: settings,
            conversationTurns: overlayTurns,
            capturedSelection: capturedSelection,
            topOffset: topOffset,
            onSubmit: { [weak self] text in
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.capturedSelection = nil
                self?.previousActiveApp = nil
                self?.followUpContext = nil
                self?.conversationTurns = []
                self?.conversationID = nil
                self?.isFollowUpFromVisibleOutputPanel = false
                self?.outputPanel.unlockFollowUp()
                Logger.app.info("Push-to-type: overlay dismissed")
            }
        )
        Logger.app.info("Push-to-type: overlay shown")
    }

    // MARK: - Text Submission Pipeline

    private func submitText(_ text: String) {
        let mode = settings.activeMode
        let selection = capturedSelection
        capturedSelection = nil
        let activeConversationID = conversationID ?? UUID()
        conversationID = nil
        let currentTurns = conversationTurns
        conversationTurns = []
        let context = followUpContext
        followUpContext = nil
        let wasFollowUpFromOutputPanel = isFollowUpFromVisibleOutputPanel
        isFollowUpFromVisibleOutputPanel = false

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
                // Step 1: Pre-processing
                let preprocessedText = mode.applyPreProcessing(text, capturedSelection: selection, followUpContext: context)

                // Step 2: Processing (optional bash script)
                let processedText: String
                switch mode.processingType {
                case .none:
                    processedText = preprocessedText
                case .bashScript:
                    processedText = try await BashRunner.run(
                        command: mode.processingCommand,
                        text: preprocessedText,
                        conversationID: activeConversationID.uuidString
                    )
                }

                // Step 3: Output
                let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
                outputDestinationOverride = nil
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
                            targetAppPID: previousActiveApp?.processIdentifier,
                            modeID: mode.id,
                            conversationID: activeConversationID,
                            canFollowUp: mode.processingType == .bashScript
                        )
                    }
                } else {
                    outputPanel.unlockFollowUp()
                    let action = makeOutputAction(for: destination, conversationID: activeConversationID)
                    try await action.execute(text: processedText)
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
                outputDestinationOverride = nil
                conversationID = nil
                conversationTurns = []
                followUpContext = nil
                isFollowUpFromVisibleOutputPanel = false
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Push-to-type failed: \(error)")
            }

            previousActiveApp = nil
        }
    }

    private func makeOutputAction(for destination: OutputDestination, conversationID: UUID) -> any PostTranscriptionAction {
        let targetPID = previousActiveApp?.processIdentifier

        switch destination.type {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bashScript:
            return OutputBashAction(
                name: destination.name,
                commandTemplate: destination.bashCommand,
                conversationID: conversationID.uuidString
            )
        case .outputPanel:
            Logger.app.warning("makeOutputAction called for outputPanel type — falling back to paste")
            return PasteAction(targetAppPID: targetPID)
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
