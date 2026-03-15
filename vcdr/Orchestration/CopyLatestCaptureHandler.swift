import AppKit
import OSLog

@MainActor
final class CopyLatestCaptureHandler {
    private let settings: AppSettings
    private let transcriptionHistory: TranscriptionHistory
    private let recordingIndicator: RecordingIndicatorPanel
    private let hotkeyManager = GlobalHotkeyManager()

    init(
        settings: AppSettings,
        transcriptionHistory: TranscriptionHistory,
        recordingIndicator: RecordingIndicatorPanel
    ) {
        self.settings = settings
        self.transcriptionHistory = transcriptionHistory
        self.recordingIndicator = recordingIndicator
    }

    func setupHotkey() {
        let binding = settings.copyLatestCaptureHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Copy latest capture hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            self?.copyLatestCapture()
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    private func copyLatestCapture() {
        guard let conversation = transcriptionHistory.latestConversation else {
            recordingIndicator.showCopyError("No captures yet")
            Logger.actions.info("Copy latest: no captures available")
            return
        }

        let textToCopy = conversation.latestOutput
        ClipboardHelper.writeString(textToCopy)

        recordingIndicator.showCopied()
        Logger.actions.info("Copied latest capture to clipboard")
    }
}
