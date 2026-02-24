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
    private let selectionCapturer: SelectionCapturer
    private let transcriptionHistory: TranscriptionHistory

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?

    // MARK: - Constants

    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(10)

    init(
        settings: AppSettings,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        transcriptionHistory: TranscriptionHistory
    ) {
        self.settings = settings
        self.recordingIndicator = recordingIndicator
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
        let transformedText = mode.transformTranscription(text, capturedSelection: capturedSelection)
        capturedSelection = nil

        // Show processing indicator
        recordingIndicator.show()
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Push-to-type: executing action")

        Task { @MainActor in
            do {
                let action = makeAction()
                let actionResult = try await action.execute(text: transformedText)

                // Record in history
                let trimmedResult = actionResult?.trimmingCharacters(in: .whitespacesAndNewlines)
                let record = TranscriptionRecord(
                    text: text,
                    modelName: "Push-to-Type",
                    recordingDuration: 0,
                    actionResult: trimmedResult?.isEmpty == false ? trimmedResult : nil
                )
                transcriptionHistory.addRecord(record)

                recordingIndicator.update(phase: .success)
                dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                Logger.app.info("Push-to-type: complete")
            } catch {
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Push-to-type failed: \(error)")
            }

            previousActiveApp = nil
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        let mode = settings.activeMode
        let targetPID = previousActiveApp?.processIdentifier
        switch mode.actionType {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bash:
            return BashAction(
                commandTemplate: mode.bashCommand,
                pasteOutput: mode.pasteScriptOutput,
                targetAppPID: targetPID
            )
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
