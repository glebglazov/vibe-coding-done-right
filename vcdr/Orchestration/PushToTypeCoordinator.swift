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

    /// Called when the override is consumed or cleared (after submission or error).
    var onOverrideConsumed: (() -> Void)?

    func updateOutputDestinationOverride(_ id: UUID?) {
        outputDestinationOverride = id
        panel.updateOutputDestinationOverride(id)
    }

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?

    // MARK: - Constants

    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(10)

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
                self?.toggleOverlay()
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

    private func toggleOverlay() {
        if panel.isVisible {
            panel.hide()
            Logger.app.info("Push-to-type: overlay dismissed via hotkey")
        } else {
            showOverlay()
        }
    }

    private func showOverlay() {
        // Capture context from the frontmost app before showing the overlay
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        capturedSelection = selectionCapturer.capture()

        panel.show(
            settings: settings,
            onSubmit: { [weak self] text in
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.capturedSelection = nil
                self?.previousActiveApp = nil
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

        // Show processing indicator
        recordingIndicator.show()
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Push-to-type: executing pipeline")

        Task { @MainActor in
            do {
                // Step 1: Pre-processing
                let preprocessedText = mode.applyPreProcessing(text, capturedSelection: selection)

                // Step 2: Processing (optional bash script)
                let processedText: String
                switch mode.processingType {
                case .none:
                    processedText = preprocessedText
                case .bashScript:
                    processedText = try await BashRunner.run(
                        command: mode.processingCommand,
                        text: preprocessedText
                    )
                }

                // Step 3: Output
                let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
                clearOverride()
                let destination = settings.outputDestination(for: destinationID)

                if destination.type == .outputPanel {
                    recordingIndicator.hide()
                    outputPanel.show(
                        text: processedText,
                        outputDestinations: settings.outputDestinations,
                        targetAppPID: previousActiveApp?.processIdentifier
                    )
                } else {
                    let action = makeOutputAction(for: destination)
                    try await action.execute(text: processedText)
                    recordingIndicator.update(phase: .success)
                    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                }

                // Record in history
                let record = TranscriptionRecord(
                    text: text,
                    processedText: processedText,
                    modelName: "Push-to-Type",
                    recordingDuration: 0,
                    actionResult: nil,
                    capturedSelection: selection
                )
                transcriptionHistory.addRecord(record)

                Logger.app.info("Push-to-type: complete")
            } catch {
                clearOverride()
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Push-to-type failed: \(error)")
            }

            previousActiveApp = nil
        }
    }

    private func makeOutputAction(for destination: OutputDestination) -> any PostTranscriptionAction {
        let targetPID = previousActiveApp?.processIdentifier

        switch destination.type {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bashScript:
            return OutputBashAction(
                name: destination.name,
                commandTemplate: destination.bashCommand
            )
        case .outputPanel:
            Logger.app.warning("makeOutputAction called for outputPanel type — falling back to paste")
            return PasteAction(targetAppPID: targetPID)
        }
    }

    private func clearOverride() {
        outputDestinationOverride = nil
        onOverrideConsumed?()
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
